time CUDA_LAUNCH_BLOCKING=1  th train.lua \
 -model ../models/en-ar-2m-75k-4layers-brnn-model_epoch13.00_5.41.t7 \
  -gpuid 1 \
 -src_dict ../data/en-ar-2m-75k.src.dict \
 -targ_dict ../data/en-ar-2m-75k.targ.dict \
 -cl_train_lbl_file ../data/rte/cl_val_lbl_file \
 -cl_val_lbl_file ../data/rte/cl_val_lbl_file \
 -cl_test_lbl_file ../data/rte/cl_val_lbl_file \
 -cl_train_source_file ../data/rte/cl_val_source_file \
 -cl_val_source_file ../data/rte/cl_val_source_file \
 -cl_test_source_file ../data/rte/cl_val_source_file \
 -cl_save /export/ssd/apoliak/nmt-repr-anaysis-sem/output \
 -cl_pred_file pred_file \
 -cl_entailment \
 -cl_train_orig_dataset_file ../data/rte/cl_val_orig_dataset_file \
 -cl_val_orig_dataset_file ../data/rte/cl_val_orig_dataset_file \
 -cl_test_orig_dataset_file ../data/rte/cl_val_orig_dataset_file \
 -cl_enc_layer 4 \
 -cl_write_test_word_repr \
 -cl_test_word_repr_file /export/ssd/apoliak/nmt-repr-anaysis-sem/output/test_word_reps
