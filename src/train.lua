-- uses code from: https://github.com/harvardnlp/seq2seq-attn

local beam = require 's2sa.beam'
require 'nn'
require 'xlua'
require 'optim'
seq = require 'pl.seq'
stringx = require 'pl.stringx'


function main()
  print(arg)
  beam.init(arg)
  opt = beam.getOptions()
  skip_start_end = model_opt.start_symbol == 1
  --print('start_symbol: ' .. model_opt.start_symbol)
  --print('skip_start_end:')
  --print(skip_start_end)
  
  classifier_opt = get_classifier_options(opt)
  classifier_opt.pred_file = paths.concat(classifier_opt.save, classifier_opt.pred_file)
  if classifier_opt.classifier_size == 0 then classifier_opt.classifier_size = model_opt.rnn_size end  
  
  assert(path.exists(classifier_opt.train_lbl_file), 'train_lbl_file does not exist')
  assert(path.exists(classifier_opt.val_lbl_file), 'val_lbl_file does not exist')
  assert(path.exists(classifier_opt.test_lbl_file), 'test_lbl_file does not exist')
  assert(path.exists(classifier_opt.train_source_file), 'train_source_file does not exist')
  assert(path.exists(classifier_opt.val_source_file), 'val_source_file does not exist')
  assert(path.exists(classifier_opt.test_source_file), 'test_source_file does not exist')
  if classifier_opt.enc_or_dec == 'dec' then
    assert(path.exists(classifier_opt.train_target_file), 'train_target_file does not exist')
    assert(path.exists(classifier_opt.val_target_file), 'val_target_file does not exist')
    assert(path.exists(classifier_opt.test_target_file), 'test_target_file does not exist')    
  end
  assert(path.exists(classifier_opt.save), 'save dir does not exist')
  
  
  -- number of module for word representation
  module_num = 2*classifier_opt.enc_layer - classifier_opt.use_cell
    
  -- first pass: get labels
  print('==> first pass: getting labels')
  label2idx, idx2label = get_labels(classifier_opt.train_lbl_file)
  local classes = {}
  for idx, _ in ipairs(idx2label) do
    table.insert(classes, idx)
  end
  classifier_opt.num_classes = #idx2label
  print('label2idx:')
  print(label2idx)
  print('idx2label:')
  print(idx2label)
  print('classes:')
  print(classes)
  
  -- second pass: prepare data as vectors
  print('==> second pass: loading data')
  local train_data, val_data, test_data = load_data(classifier_opt, label2idx)
    
  -- use trained encoder/decoder from MT model
  encoder, decoder = model[1], model[2]
  if model_opt.brnn == 1 then
    encoder_brnn = model[4]
  end
  
  -- define classifier
  classifier = nn.Sequential()
  classifier:add(nn.Linear(model_opt.rnn_size,classifier_opt.classifier_size))
  classifier:add(nn.Dropout(classifier_opt.classifier_dropout))
  classifier:add(nn.ReLU(true))
  classifier:add(nn.Linear(classifier_opt.classifier_size, classifier_opt.num_classes)) 
  print('==> defined classification model:')
  print(classifier)
    
  -- define classification criterion
  criterion = nn.CrossEntropyCriterion()
  
  -- move to cuda
  if opt.gpuid >= 0 then     
    classifier = classifier:cuda()
    criterion = criterion:cuda()
  end
  
  -- get classifier parameters and gradients
  classifier_params, classifier_grads = classifier:getParameters()
  
  -- define optimizer
  if classifier_opt.optim == 'ADAM' then
    optim_state = {learningRate = classifier_opt.learning_rate}
    optim_method = optim.adam
  elseif classifier_opt.optim == 'ADAGRAD' then
    optim_state = {learningRate = classifier_opt.learning_rate}
    optim_method = optim.adagrad
  elseif classifier_opt.optim == 'ADADELTA' then
    optim_state = {}
    optim_method = optim.adadelta
  else
    optim_state = {learningRate = classifier_opt.learning_rate}
    optim_method = optim.sgd
  end
  
  
  confusion = optim.ConfusionMatrix(classes)
  
  -- Log results to files
  train_logger = optim.Logger(paths.concat(classifier_opt.save, 'train.log'))
  val_logger = optim.Logger(paths.concat(classifier_opt.save, 'val.log'))  
  test_logger = optim.Logger(paths.concat(classifier_opt.save, 'test.log'), classifier_opt.pred_file)  
  
  collectgarbage(); collectgarbage();
  
  -- do epochs
  local epoch, best_epoch, best_loss = 1, 1, math.huge
  while epoch <= classifier_opt.epochs and epoch - best_epoch <= classifier_opt.patience do 
    train(train_data, epoch)
    val_loss = eval(val_data, epoch, val_logger, 'val')
    if val_loss < best_loss then
      best_epoch = epoch
      best_loss = val_loss
      if classifier_opt.save_model == 1 then
        -- save current model
        local filename = paths.concat(classifier_opt.save, 'classifier_model_epoch_' .. epoch .. '.t7')
        os.execute('mkdir -p ' .. sys.dirname(filename))
        print('==> saving model to '..filename)
        torch.save(filename, classifier)        
      end
    end
    eval(test_data, epoch, test_logger, 'test', classifier_opt.pred_file)
    print('finished epoch ' .. epoch .. ', with val loss: ' .. val_loss)
    print('best epoch: ' .. best_epoch .. ', with val loss: ' .. best_loss)
    epoch = epoch + 1    
    collectgarbage(); collectgarbage();
  end
  if epoch - best_epoch > classifier_opt.patience then
    print('==> reached patience of ' .. classifier_opt.patience .. ' epochs, stopping...')
  end  
end
  
function train(train_data, epoch)
  
  local time = sys.clock()
  classifier:training()
  -- TODO maybe don't set encoder to training here
  encoder:training(); decoder:training();
  if model_opt.brnn == 1 then encoder_brnn:training() end
  
  local shuffle = torch.randperm(#train_data)
  
  print('\n==> doing epoch on training data:')
  print('\n==> epoch # ' .. epoch .. ' [batch size = ' .. classifier_opt.batch_size .. ']')
  
  local total_loss, num_total_words = 0, 0
  for i = 1,#train_data, classifier_opt.batch_size do
    collectgarbage()
    xlua.progress(i, #train_data)
    
    -- prepare mini-batch
    local batch_input, batch_labels = {}, {}
    for j = i,math.min(i+classifier_opt.batch_size-1, #train_data) do
      local source = train_data[shuffle[j]][1]      
      if opt.gpuid >= 0 then source = source:cuda() end
      local input, labels = {source}
      if classifier_opt.enc_or_dec == 'enc' then
        labels = train_data[shuffle[j]][2]
      elseif classifier_opt.enc_or_dec == 'dec' then
        local target = train_data[shuffle[j]][2]
        --if opt.gpuid >= 0 then target = target:cuda() end
        target = target:long()
        table.insert(input, target)
        labels = train_data[shuffle[j]][3]
      else
        error('unknown value for classifier_opt.enc_or_dec: ' .. classifier_opt.enc_or_dec)
      end          
      table.insert(batch_input, input)
      table.insert(batch_labels, labels)
    end
    
    -- closure
    local eval_loss_grad = function(x) 
      -- get new params
      if x ~= classifier_params then classifier_params:copy(x) end
      
      -- reset gradients
      classifier_grads:zero()
      
      local loss, num_words = 0, 0
      for j = 1,#batch_input do
        local source = batch_input[j][1]
        if classifier_opt.verbose then 
          print('source:'); print(source);
          print(indices_to_string(source, idx2word_src))
        end
        local source_l = math.min(source:size(1), opt.max_sent_l)
        if classifier_opt.verbose then 
          print('source_l: ' .. source_l)
          print('opt.max_sent_l: ' .. opt.max_sent_l)
        end
        local source_input
        if model_opt.use_chars_enc == 1 then
          source_input = source:view(source_l, 1, source:size(2)):contiguous()
        else
          source_input = source:view(source_l, 1)
        end
        if classifier_opt.verbose then
          print('source_input:'); print(source_input);
        end

        local rnn_state_enc = {}
        for i = 1, #init_fwd_enc do
          table.insert(rnn_state_enc, init_fwd_enc[i]:zero())
        end
        local context = context_proto[{{}, {1,source_l}}]:clone() -- 1 x source_l x rnn_size
        
        -- forward encoder
        if classifier_opt.verbose then print('forward fwd encoder') end
        for t = 1, source_l do
          --print('skip_start_end:')
          --print(skip_start_end)
          -- forward encoder
          local encoder_input = {source_input[t], table.unpack(rnn_state_enc)}
          local enc_out = encoder:forward(encoder_input)
          rnn_state_enc = enc_out
          context[{{},t}]:copy(enc_out[module_num])
          if classifier_opt.verbose then
            print('t: ' .. t)
            print('encoder_input:'); print(encoder_input)
            print('enc_out:'); print(enc_out);
          end
        end
        
        local rnn_state_dec = {}
        for i = 1, #init_fwd_dec do
          table.insert(rnn_state_dec, init_fwd_dec[i]:zero())
        end
        
        if model_opt.init_dec == 1 then
          for L = 1, model_opt.num_layers do
            rnn_state_dec[L*2-1+model_opt.input_feed]:copy(rnn_state_enc[L*2-1])
            rnn_state_dec[L*2+model_opt.input_feed]:copy(rnn_state_enc[L*2])
          end
        end                
        
        if model_opt.brnn == 1 then
          for i = 1, #rnn_state_enc do
            rnn_state_enc[i]:zero()
          end
          -- forward bwd encoder
          if classifier_opt.verbose then print('forward bwd encoder') end
          for t = source_l, 1, -1 do
            
            local encoder_input = {source_input[t], table.unpack(rnn_state_enc)}
            local enc_out = encoder_brnn:forward(encoder_input)
            rnn_state_enc = enc_out
            context[{{},t}]:add(enc_out[module_num])
            if classifier_opt.verbose then
              print('t: ' .. t)
              print('encoder_input:'); print(encoder_input);
              print('enc_out:'); print(enc_out);
            end
          end
          if model_opt.init_dec == 1 then
            for L = 1, model_opt.num_layers do
              rnn_state_dec[L*2-1+model_opt.input_feed]:add(rnn_state_enc[L*2-1])
              rnn_state_dec[L*2+model_opt.input_feed]:add(rnn_state_enc[L*2])
            end
          end          
        end
        
        local dec_all_out, target_l
        if classifier_opt.enc_or_dec == 'dec' then
          local target = batch_input[j][2]
          target_l = math.min(target:size(1), opt.max_sent_l)
          if classifier_opt.verbose then
            print('target:'); print(target);
            print(indices_to_string(target, idx2word_targ))
            print('target_l: ' .. target_l)
          end            
          dec_all_out = context_proto[{{}, {1,target_l}}]:clone() 
          -- forward decoder
          if classifier_opt.verbose then print('forward decoder') end
          for t = 2, target_l do 
            local decoder_input1
            if model_opt.use_chars_dec == 1 then
              --decoder_input1 = word2charidx_targ:index(1, target[{{t-1}}]:long())
              decoder_input1 = word2charidx_targ:index(1, target[{{t-1}}])
            else
              decoder_input1 = target[{{t-1}}]
            end
            local decoder_input
            if model_opt.attn == 1 then
              decoder_input = {decoder_input1, context[{{1}}], table.unpack(rnn_state_dec)}
            else
              decoder_input = {decoder_input1, context[{{1}, source_l}], table.unpack(rnn_state_dec)}
            end
            local out_decoder = decoder:forward(decoder_input)
            --local out = model[3]:forward(out_decoder[#out_decoder]) -- K x vocab_size
            rnn_state_dec = {} -- to be modified later
            if model_opt.input_feed == 1 then
              table.insert(rnn_state_dec, out_decoder[#out_decoder])
            end
            for j = 1, #out_decoder - 1 do
              table.insert(rnn_state_dec, out_decoder[j])
            end
            dec_all_out[{{},t}]:copy(out_decoder[module_num])   
            if classifier_opt.verbose then
              print('t: ' .. t)
              print('decoder_input1:'); print(decoder_input1);
              print('decoder_input:'); print(decoder_input);
              print('out_decoder:'); print(out_decoder);
              print('rnn_state_dec:'); print(rnn_state_dec);
            end
          end                            
        end
        
        -- take encoder/decoder output as input to classifier
        local classifier_input_all
        if classifier_opt.enc_or_dec == 'dec' then
          -- always ignore start and end sybmols in dec
          local end_idx = target_l == opt.max_sent_len and target_l or target_l-1
          classifier_input_all = dec_all_out[{{}, {2,end_idx}}]
        else
          if not skip_start_end then
            classifier_input_all = context
          else
            local end_idx = source_l == opt.max_sent_len and source_l or source_l-1
            classifier_input_all = context[{{}, {2,end_idx}}]
          end
        end
        
        if classifier_opt.verbose then 
          print('classifier_input_all:'); print(classifier_input_all);
          print('batch_labels[j]:'); print(batch_labels[j])
          print('string format: ' .. indices_to_string(batch_labels[j], idx2label))
          -- forward/backward classifier
          print('forward/backward classifier')
        end
        for t = 1, classifier_input_all:size(2) do
          local classifier_input = classifier_input_all[{{},t}]
          classifier_input = classifier_input:view(classifier_input:nElement())
          local classifier_out = classifier:forward(classifier_input)
          loss = loss + criterion:forward(classifier_out, batch_labels[j][t])
          num_words = num_words + 1
          local output_grad = criterion:backward(classifier_out, batch_labels[j][t])
          classifier:backward(classifier_input, output_grad)
          
          if classifier_opt.verbose then 
            print('t: ' .. t)
            print('classifier_input:'); print(classifier_input);
            print('classifier_out:'); print(classifier_out);
            print('batch_labels[j][t]: ' .. batch_labels[j][t])
            print('loss:'); print(loss);
            print('output_grad:'); print(output_grad);
          end
          
          -- update confusion matrix
          confusion:add(classifier_out, batch_labels[j][t])
        end    
      end
      
      -- TODO consider normalizing over batch size instead of num words in batch 
      classifier_grads:div(num_words)
      -- keep loss over entire training data
      total_loss = total_loss + loss
      num_total_words = num_total_words + num_words
      -- loss for current batch
      loss = loss/num_words
      
      -- TODO clip gradients?
      
      return loss, classifier_grads      
    end
    
    optim_method(eval_loss_grad, classifier_params, optim_state)
  
  end
  
  time = (sys.clock() - time) / #train_data
  print('==> time to learn 1 sample = ' .. (time*1000) .. 'ms') 
  total_loss = total_loss/num_total_words
  print('==> loss: ' .. total_loss)  
  print(confusion)
  
   -- update logger/plot
  train_logger:add{['% mean class accuracy (train set)'] = confusion.totalValid * 100}
  if classifier_opt.plot then
    train_logger:style{['% mean class accuracy (train set)'] = '-'}
    train_logger:plot()
  end  
   
  -- for next epoch
  confusion:zero()
      
end


function eval(data, epoch, logger, test_or_val, pred_filename)
  test_or_val = test_or_val or 'test'
  local pred_file
  if pred_filename then
    pred_file = torch.DiskFile(pred_filename .. '.epoch' .. epoch, 'w')
  end
  
  local time = sys.clock()
  classifier:evaluate()
  encoder:evaluate(); decoder();
  if model_opt.brnn == 1 then encoder_brnn:evaluate() end
  
  print('\n==> evaluating on ' .. test_or_val .. ' data')
  print('==> epoch: ' .. epoch)
  local loss, num_words = 0, 0
  for i=1,#data do 
    xlua.progress(i, #data)
    local source, target, labels = data[i][1]
    if opt.gpuid >= 0 then source = source:cuda() end
    if classifier_opt.enc_or_dec == 'enc' then
      labels = data[i][2]      
    else
      target = data[i][2]
      if opt.gpuid >= 0 then target = target:cuda() end
      labels = data[i][3]
    end
    
    local source_l = math.min(source:size(1), opt.max_sent_l)
    local source_input
    if model_opt.use_chars_enc == 1 then
      source_input = source:view(source_l, 1, source:size(2)):contiguous()
    else
      source_input = source:view(source_l, 1)
    end

    local rnn_state_enc = {}
    for i = 1, #init_fwd_enc do
      table.insert(rnn_state_enc, init_fwd_enc[i]:zero())
    end
    local context = context_proto[{{}, {1,source_l}}]:clone() -- 1 x source_l x rnn_size
    
    -- forward encoder
    for t = 1, source_l do
      local encoder_input = {source_input[t], table.unpack(rnn_state_enc)}
      local enc_out = encoder:forward(encoder_input)
      rnn_state_enc = enc_out
      context[{{},t}]:copy(enc_out[module_num])
    end
    
    local rnn_state_dec = {}
    for i = 1, #init_fwd_dec do
      table.insert(rnn_state_dec, init_fwd_dec[i]:zero())
    end
    
    if model_opt.init_dec == 1 then
      for L = 1, model_opt.num_layers do
        rnn_state_dec[L*2-1+model_opt.input_feed]:copy(rnn_state_enc[L*2-1])
        rnn_state_dec[L*2+model_opt.input_feed]:copy(rnn_state_enc[L*2])
      end
    end                    
    
    if model_opt.brnn == 1 then
      for i = 1, #rnn_state_enc do
        rnn_state_enc[i]:zero()
      end
      -- forward backward encoder
      for t = source_l, 1, -1 do
        local encoder_input = {source_input[t], table.unpack(rnn_state_enc)}
        local enc_out = encoder_brnn:forward(encoder_input)
        rnn_state_enc = enc_out
        context[{{},t}]:add(enc_out[module_num])
      end
      if model_opt.init_dec == 1 then
        for L = 1, model_opt.num_layers do
          rnn_state_dec[L*2-1+model_opt.input_feed]:add(rnn_state_enc[L*2-1])
          rnn_state_dec[L*2+model_opt.input_feed]:add(rnn_state_enc[L*2])
        end
      end                
    end
    
    local dec_all_out, target_l
    if classifier_opt.enc_or_dec == 'dec' then
      target_l = math.min(target:size(1), opt.max_sent_l)
      dec_all_out = context_proto[{{}, {1,target_l}}]:clone() 
      -- forward decoder
      for t = 2, target_l do 
        local decoder_input1
        if model_opt.use_chars_dec == 1 then
          decoder_input1 = word2charidx_targ:index(1, target[{{t-1}}]:long())
        else
          decoder_input1 = target[{{t-1}}]
        end
        local decoder_input
        if model_opt.attn == 1 then
          decoder_input = {decoder_input1, context[{{1}}], table.unpack(rnn_state_dec)}
        else
          decoder_input = {decoder_input1, context[{{1}, source_l}], table.unpack(rnn_state_dec)}
        end
        local out_decoder = decoder:forward(decoder_input)
        --local out = model[3]:forward(out_decoder[#out_decoder]) -- K x vocab_size
        rnn_state_dec = {} -- to be modified later
        if model_opt.input_feed == 1 then
          table.insert(rnn_state_dec, out_decoder[#out_decoder])
        end
        for j = 1, #out_decoder - 1 do
          table.insert(rnn_state_dec, out_decoder[j])
        end
        dec_all_out[{{},t}]:copy(out_decoder[module_num])                      
      end                            
    end  
    
    -- take encoder/decoder output as input to classifier
    local classifier_input_all
    if classifier_opt.enc_or_dec == 'dec' then
      -- always ignore start and end sybmols in dec
      local end_idx = target_l == opt.max_sent_len and target_l or target_l-1
      classifier_input_all = dec_all_out[{{}, {2,end_idx}}]
    else
      if not skip_start_end then
        classifier_input_all = context
      else
        local end_idx = source_l == opt.max_sent_len and source_l or source_l-1
        classifier_input_all = context[{{}, {2,end_idx}}]
      end
    end
    
    -- forward classifier    
    local pred_labels = {}
    for t = 1, classifier_input_all:size(2) do
      -- take word representation
      --local classifier_input = enc_out[2*classifier_opt.enc_layer - classifier_opt.use_cell]
      local classifier_input = classifier_input_all[{{},t}]      
      classifier_input = classifier_input:view(classifier_input:nElement())        
      local classifier_out = classifier:forward(classifier_input)
      -- get predicted labels to write to file
      if pred_file then
        local _, pred_idx =  classifier_out:max(1)
        pred_idx = pred_idx:long()[1]
        local pred_label = idx2label[pred_idx]
        table.insert(pred_labels, pred_label)
      end
      
      loss = loss + criterion:forward(classifier_out, labels[t])
      num_words = num_words + 1
      
      confusion:add(classifier_out, labels[t])
    end
    if pred_file then
      pred_file:writeString(stringx.join(' ', pred_labels) .. '\n')
    end
    
  end
  loss = loss/num_words
  
  time = (sys.clock() - time) / #data
  print('==> time to evaluate 1 sample = ' .. (time*1000) .. 'ms') 
  print('==> loss: ' .. loss)
  
  print(confusion)
  
   -- update log/plot
   logger:add{['% mean class accuracy (' .. test_or_val .. ' set)'] = confusion.totalValid * 100}
   if classifier_opt.plot then
      logger:style{['% mean class accuracy (' .. test_or_val .. ' set)'] = '-'}
      logger:plot()
   end
   
  -- next epoch
  confusion:zero()
  
  if pred_file then pred_file:close() end
  return loss
  
end


function load_data(classifier_opt, label2idx)
  local train_data, val_data, test_data
  if classifier_opt.enc_or_dec == 'enc' then
    unknown_labels = 0
    train_data = load_source_data(classifier_opt.train_source_file, classifier_opt.train_lbl_file, label2idx, classifier_opt.max_sent_len) 
    print('==> words with unknown labels in train data: ' .. unknown_labels)
    unknown_labels = 0
    val_data = load_source_data(classifier_opt.val_source_file, classifier_opt.val_lbl_file, label2idx) 
    print('==> words with unknown labels in val data: ' .. unknown_labels)
    unknown_labels = 0
    test_data = load_source_data(classifier_opt.test_source_file, classifier_opt.test_lbl_file, label2idx)   
    print('==> words with unknown labels in test data: ' .. unknown_labels)
  else
    unknown_labels = 0
    train_data = load_source_target_data(classifier_opt.train_source_file, classifier_opt.train_target_file, classifier_opt.train_lbl_file, label2idx, classifier_opt.max_sent_len) 
    print('==> words with unknown labels in train data: ' .. unknown_labels)
    unknown_labels = 0
    val_data = load_source_target_data(classifier_opt.val_source_file, classifier_opt.val_target_file, classifier_opt.val_lbl_file, label2idx) 
    print('==> words with unknown labels in val data: ' .. unknown_labels)
    unknown_labels = 0
    test_data = load_source_target_data(classifier_opt.test_source_file, classifier_opt.test_target_file, classifier_opt.test_lbl_file, label2idx)   
    print('==> words with unknown labels in test data: ' .. unknown_labels)    
  end
  return train_data, val_data, test_data
end


function load_source_data(file, label_file, label2idx, max_sent_len) 
  local max_sent_len = max_sent_len or math.huge
  local data = {}
  for line, labels in seq.zip(io.lines(file), io.lines(label_file)) do
    sent = beam.clean_sent(line)
    local source
    if model_opt.use_chars_enc == 0 then
      source, _ = beam.sent2wordidx(line, word2idx_src, model_opt.start_symbol)
    else
      source, _ = beam.sent2charidx(line, char2idx, model_opt.max_word_l, model_opt.start_symbol)
    end    
    local label_idx = {}
    for label in labels:gmatch'([^%s]+)' do
      if label2idx[label] then
        idx = label2idx[label]
      else
        print('Warning: unknown label ' .. label .. ' in line: ' .. line .. ' with labels ' .. labels)
        print('Warning: using idx 0 for unknown')
        idx = 0
        unknown_labels = unknown_labels + 1
      end
      table.insert(label_idx, idx)
    end
    if #label_idx <= max_sent_len then
      table.insert(data, {source, label_idx})
    end
  end
  return data
end


function load_source_target_data(source_file, target_file, target_label_file, label2idx, max_sent_len)
  local max_sent_len = max_sent_len or math.huge
  local data = {}
  for source_line, target_line, labels in seq.zip3(io.lines(source_file), io.lines(target_file), io.lines(target_label_file)) do
    source_sent = beam.clean_sent(source_line)
    local source
    if model_opt.use_chars_enc == 0 then
      source, _ = beam.sent2wordidx(source_line, word2idx_src, model_opt.start_symbol)
    else
      source, _ = beam.sent2charidx(source_line, char2idx, model_opt.max_word_l, model_opt.start_symbol)
    end
    
    target_sent = beam.clean_sent(target_line)
    local target
    -- TODO make sure it's correct to always use start_symbol here (last argument) -> check the effect during training, maybe need to ignore this symbol
    if model_opt.use_chars_dec == 0 then
      target, _ = beam.sent2wordidx(target_line, word2idx_targ, 1)
    else
      --target, _ = beam.sent2charidx(target_line, char2idx, model_opt.max_word_l, 1)
      target, _ = beam.sent2wordidx(target_line, word2idx_targ, 1)
    end
    
    local label_idx = {}
    for label in labels:gmatch'([^%s]+)' do
      if label2idx[label] then
        idx = label2idx[label]
      else
        print('Warning: unknown label ' .. label .. ' in target line: ' .. target_line .. ' with labels ' .. labels)
        print('Warning: using idx 0 for unknown')
        idx = 0
        unknown_labels = unknown_labels + 1
      end
      table.insert(label_idx, idx)
    end
    if #label_idx <= max_sent_len then
      table.insert(data, {source, target, label_idx})
    end
  end
  return data

end


function get_labels(label_file)
  local label2idx, idx2label = {}, {}
  for line in io.lines(label_file) do
    for label in line:gmatch'([^%s]+)' do
      if not label2idx[label] then
        idx2label[#idx2label+1] = label
        label2idx[label] = #idx2label
      end
    end
  end
  return label2idx, idx2label
end


function seq.zip3(iter1, iter2, iter3)
  iter1 = seq.iter(iter1)
  iter2 = seq.iter(iter2)
  iter3 = seq.iter(iter3)
  return function()
    return iter1(),iter2(),iter3()
  end
end


function get_classifier_options(opt)
  local classifier_opt = {}
  for op, val in pairs(opt) do
    if stringx.startswith(op, 'cl_') then 
      classifier_opt[op:sub(4)] = val
    end
  end
  return classifier_opt
end


function indices_to_string(indices, idx_map)
  local ind, tab = indices, {}
  if torch.type(ind) ~= 'table' then
    ind = ind:totable()
  end
  for _, v in pairs(ind) do 
    if idx_map[v] then
      table.insert(tab, idx_map[v])
    end
  end
  return table.concat(tab, ' ')
end

main()

