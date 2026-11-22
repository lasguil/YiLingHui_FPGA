#define sp_request_model reference_sp_request_model
#define sp_submit reference_sp_submit
#define sp_poll reference_sp_poll
#define sp_abort reference_sp_abort
#define sp_load_color_table reference_sp_load_color_table
#define sp_load_color_table_builtin reference_sp_load_color_table_builtin
#include "../../support/firmware_cleanup_20261112/software/style_pipeline.c"
int reference_check_frame(const struct sp_frame *frame){return valid_frame(frame);}
