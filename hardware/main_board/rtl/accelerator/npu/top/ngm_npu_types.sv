// 协议契约：本包只定义顶层模块间的具名连线，packed struct不包含存储、握手状态或隐式流水。
// 所有valid/ready延用原模块协议；字段方向由各包装模块端口定义，只有一个驱动者。
// 行描述符由任务控制保持，工作复位不传给host；DDR已接受事务在中止时排空。
package ngm_npu_types; // NPU系统集成接口类型。

    typedef struct packed { // 软件挂起命令与DDR帧布局。
        logic frame_valid; // 软件帧命令挂起，直到frame_ready接受。
        logic model_valid; // 软件换模型命令挂起，可抢占当前帧。
        logic [10:0] frame_width4; // 尺寸必须为真实图像除四。
        logic [10:0] frame_height4; // 尺寸必须为真实图像除四。
        logic [31:0] frame_input_base; // DDR字节首地址。
        logic [31:0] frame_output_base; // DDR字节首地址。
        logic [31:0] frame_x0_base; // DDR字节首地址。
        logic [31:0] model_base; // DDR字节首地址。
        logic [23:0] frame_input_stride; // DDR字节行跨度。
        logic [23:0] frame_output_stride; // DDR字节行跨度。
        logic [23:0] frame_x0_stride; // DDR字节行跨度。
    } command_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 总线静止状态与共享低拍寄存器。
        logic [127:0] scratch_value; // 帧X0低拍复用模型装载器既有128位寄存器。
        logic idle; // B响应结束、错误及总线静止。
    } host_aux_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // DDR读命令握手、128位返回拍和完成事件。
        logic ready; // 单读命令可以接受。
        logic data_valid; // 当前R拍供适配器消费。
        logic [127:0] data; // AXI低字节对应低DDR地址。
        logic [15:0] keep; // 有效字节位，只有命令最后一拍可能非全一。
        logic last; // 命令末拍、响应结束及错误。
        logic done; // 命令末拍、响应结束及错误。
        logic error; // 命令末拍、响应结束及错误。
    } read_response_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // DDR写命令握手、W消费和B完成事件。
        logic ready; // 单写命令可以接受。
        logic data_ready; // 当前W拍可接受。
        logic done; // B响应结束、错误及总线静止。
        logic error; // B响应结束、错误及总线静止。
    } write_response_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 整表权重装载的接受与完成事件。
        logic ready; // DDR读端空闲，允许开始装载。
        logic done; // 成功或失败互斥单拍，均等待主表写入与DDR响应结束。
        logic error; // 成功或失败互斥单拍，均等待主表写入与DDR响应结束。
    } model_response_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 主表40位项写流，地址与数据同valid保持。
        logic valid; // 主表40位项写请求。
        logic [11:0] addr; // 主表项地址。
        logic [39:0] data; // 连续五字节小端项。
    } weight_write_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 软件可见状态与终结事件。
        logic frame_ready; // 帧级控制实际接收。
        logic model_ready; // 帧级控制实际接收。
        logic model_loaded; // 完整权重包可供帧运算使用。
        logic busy; // 当前存在帧任务、模型装载或安全排空。
        logic frame_done; // 最后成功B之后的一拍整帧成功事件。
        logic frame_aborted; // 当前帧被换模型抢占后的一拍终止事件。
        logic model_done; // 完整主表与DDR读响应均提交后的成功事件。
        logic task_error; // 当前任务安全终止后的一拍失败事件。
        logic [2:0] error_code; // 帧级错误原因。
    } status_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 帧命令锁存的尺寸、DDR基址与行跨度。
        logic [31:0] input_base; // 锁存配置，不随软核改寄存器变化。
        logic [31:0] output_base; // 锁存配置，不随软核改寄存器变化。
        logic [31:0] x0_base; // 锁存配置，不随软核改寄存器变化。
        logic [23:0] input_stride; // 锁存DMA行跨度。
        logic [23:0] output_stride; // 锁存DMA行跨度。
        logic [23:0] x0_stride; // 锁存DMA行跨度。
        logic [10:0] width4; // 当前帧四分之一宽。
        logic [10:0] height4; // 当前帧四分之一高。
    } frame_config_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 排空之后授权的权重镜像装载命令。
        logic [31:0] address; // 已锁存的权重镜像地址。
        logic valid; // 帧控制器授权开始装载，不直接使用软件挂起命令。
    } model_request_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 帧抢占及安全工作状态清除。
        logic abort_req; // 中止当前DDR命令，仅取消未发起的后续burst。
        logic clear_work; // 丢帧停止新工作与安全工作状态清除。
    } phase_control_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 当前strip范围、边界脉冲及D物理保存布局。
        logic start; // 存储相位及主体新strip标签清除。
        logic [10:0] s; // strip中心、D基址与RGB局部保存宽。
        logic [10:0] e; // strip中心、D基址与RGB局部保存宽。
        logic [10:0] tail_base; // strip中心、D基址与RGB局部保存宽。
        logic [10:0] bank_rgb_width; // strip中心、D基址与RGB局部保存宽。
    } strip_context_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 当前Stem任务所需的两条RGB输入行。
        logic valid; // Stem所需两条RGB输入行的流式DMA命令。
        logic [10:0] row; // 第一条真实RGB行，第二条为加一。
        logic [10:0] width; // 两行各自真实像素宽度。
    } input_command_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 当前主体行的X0读回区间及C中心范围。
        logic valid; // 主体X0行预取命令，末字同时提交C/D。
        logic [10:0] row; // X0真实行号。
        logic [10:0] lo; // X0范围与C中心。
        logic [10:0] hi; // X0范围与C中心。
        logic [10:0] center_lo; // X0范围与C中心。
        logic [10:0] center_hi; // X0范围与C中心。
    } x0_command_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 行描述符，接受后保持至计算和DDR共同完成。
        logic valid; // 前端或主体整行计算命令。
        logic [4:0] layer; // 当前层0..16。
        logic [10:0] id; // 输出行与输入真实高度。
        logic [10:0] read_height; // 输出行与输入真实高度。
        logic [10:0] x; // 真实组首列、AB局部首列和输入宽度。
        logic [10:0] ab_col; // 真实组首列、AB局部首列和输入宽度。
        logic [10:0] read_width; // 真实组首列、AB局部首列和输入宽度。
        logic [9:0] count; // 实际空间组数。
        logic [1:0] read_slot; // 三行环输入与输出槽。
        logic [1:0] write_slot; // 三行环输入与输出槽。
        logic [10:0] read_lo; // 输入保存范围与有效输出范围。
        logic [10:0] read_hi; // 输入保存范围与有效输出范围。
        logic [10:0] emit_lo; // 输入保存范围与有效输出范围。
        logic [10:0] emit_hi; // 输入保存范围与有效输出范围。
        logic [10:0] read_center_lo; // 主体C中心描述符。
        logic [10:0] read_center_hi; // 主体C中心描述符。
        logic [10:0] write_center_lo; // 主体C中心描述符。
        logic [10:0] write_center_hi; // 主体C中心描述符。
    } row_command_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 当前行执行期间可准备的下一模型层。
        logic valid; // 当前行期间下一实际层提示。
        logic [4:0] layer; // 提示层号。
    } weight_hint_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 行定序器的配置、issue节拍及结果坐标。
        logic cmd_ready; // 接受命令指示。
        logic busy; // 当前存在帧任务、模型装载或安全排空。
        logic row_done; // 当前计算行的结果已全部进入目标存储。
        logic [4:0] stage_layer_id; // 正在执行层，保持至完成。
        logic [10:0] stage_row; // 正在执行行。
        logic engine_row_start_valid; // 首窗口和行配置联合启动请求。
        logic protocol_error; // 命令或无回压结果错误保持。
    } feedback_row_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 抽头读请求、装填写使能及窗口完成状态。
        logic stem_ready; // 直接写窗时接受。
        logic [1:0] load_valid; // 现有窗口两写口。
        logic idle; // 排空和硬件错误保持。
        logic protocol_error; // 排空和硬件错误保持。
    } feedback_window_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 按实际issue对齐的残差读请求。
        logic protocol_error; // 错过请求时隙保持错误到复位。
    } feedback_residual_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 行引擎的权重提交、窗口消费及计算结果。
        logic row_ready; // 现有行引擎行握手。
        logic window_released; // 点末issue和本行末点。
        logic code_valid; // 这一拍有一个结果码
        logic pixel_valid; // 这一拍有 5 个像素
        logic [39:0] pixel_bytes; // 5 个字节：第 i 个字节 = 本组第 5*beat+i 个字节
        logic protocol_error; // 自查：上面四条里任意一条中了
    } feedback_engine_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 片上存储的握手、读返回及结果整理接口。
        logic io_wr_ready; // C已分配空闲字的输出队列写。
        logic io_rd_ready; // C输出队列原生读。
        logic io_rsp_valid; // 原生返回保持。
        logic [255:0] io_rsp_word; // 输出队列原生整字。
        logic [127:0] prefix_value; // 对齐器的分时共享寄存器。
        logic req_ready; // 所有参与客户原子接受。
        logic d_rsp_valid; // D 单字返回。
        logic [127:0] d_rsp_input_word; // 输入段直连D组0 A口。
        logic [255:0] d_rsp_word; // RAM原生整字，不复制宽暂存。
        logic checkpoint_valid; // Down 的整帧 X0 写出。
        logic dma_ready; // 所需目标全部可收。
        logic layer_load_ready; // 本层权重装载可开始。
        logic layer_load_done; // 权重装载完成与流有效。
        logic reload_ready; // 主表接受该项。
        logic protocol_error; // 子模块与路由错误合并。
    } feedback_memory_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // RGB输入分段DMA的状态及D段暂存写流。
        logic start_ready; // 命令接受与数据消费/读响应结束。
        logic busy; // 当前存在帧任务、模型装载或安全排空。
        logic done; // 命令接受与数据消费/读响应结束。
        logic error; // 行占用与互斥终结脉冲。
        logic dma_valid; // 上行拍写D原有空闲尾区。
        logic [10:0] dma_row; // D提交输入段时使用Stem行标签。
        logic [7:0] dma_word; // 段内拍号0..23。
        logic [255:0] dma_data; // 低128位有效，高半为零，无新增配对暂存。
        logic dma_last; // 上行段末拍真正握手时提交。
    } feedback_input_dma_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 上行段读取和上下行像素配对接口。
        logic req_valid; // 请求D下一原始DDR拍。
        logic [4:0] req_word; // 段内拍号，不是像素列。
        logic rsp_ready; // 当前整字已使用完或需跨字。
        logic pair_valid; // 一对上下行相邻像素已齐。
        logic [127:0] pair_data; // 十二个输入通道与零填充。
    } feedback_input_pair_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // C输出队列、共享RGB前缀及行提交状态。
        logic row_ready; // 输出行、响应与预留名额。
        logic done; // 输出行、响应与预留名额。
        logic error; // 输出行、响应与预留名额。
        logic quiescent; // 输出行、响应与预留名额。
        logic window_room; // 输出行、响应与预留名额。
        logic sink_ready; // RGB字节有效和输出队列接收。
        logic io_wr_valid; // C已分配空闲字的输出队列写。
        logic [9:0] io_wr_addr; // 队列物理地址。
        logic [42:0] io_rgb_word; // RGB五字节与三位有效长度，Down整字已经在rf_data上。
        logic io_rd_valid; // C输出队列原生读。
        logic [9:0] io_rd_addr; // 队列物理读地址。
        logic io_rsp_ready; // 原生返回保持。
        logic prefix_write; // RGB对齐更新整理器既有寄存器。
        logic [127:0] prefix_data; // RGB对齐更新整理器既有寄存器。
    } feedback_output_dma_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // X0行读回的状态及原子C/D写流。
        logic start_ready; // X0命令接受与末字提交。
        logic busy; // 当前存在帧任务、模型装载或安全排空。
        logic done; // X0命令接受与末字提交。
        logic error; // 行接收与终结事件。
        logic dma_valid; // 完整256位字原子提交。
        logic [10:0] dma_row; // 不复制外部保持描述符。
        logic [10:0] dma_x; // 不复制外部保持描述符。
        logic [10:0] dma_center_lo; // DMA 的 C 中心范围。
        logic [10:0] dma_center_hi; // DMA 的 C 中心范围。
        logic [7:0] dma_word; // D预取的范围内字序号。
        logic [255:0] dma_data; // 当前整字与提交标记。
        logic dma_begin; // 当前整字与提交标记。
        logic dma_last; // 当前整字与提交标记。
    } feedback_x0_dma_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 固定模型的合法层检查与权重地址。
        logic desc_valid; // 当前层号有效。
    } feedback_descriptor_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 任务控制对内部工作模块的授权。
        logic reset_work; // 全局复位或帧控制安全清工作状态。
        logic output_stage; // Down或RGB当前行需要DDR提交。
        logic weights_ready; // 准备权重bank已完成且层号匹配。
        logic row_cmd_take; // 行计算与输出队列同沿接受描述符。
        logic [4:0] wanted_layer; // 当前待装载权重的模型层号。
        logic layer_load_start; // 只在非活动权重bank可复用时开始装载。
        logic [10:0] output_columns; // 当前输出行的真实有效列数。
        logic tail_parity; // 已被Reduce完整消费、允许复用的X4行槽parity。
    } dispatch_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 四条顺序DDR流的当前行首地址。
        logic [31:0] input_address; // 下一对输入行的DDR首地址。
        logic [31:0] checkpoint_address; // 下一整帧X0写行的DDR首地址。
        logic [31:0] prefetch_address; // 当前strip下一X0读行的DDR首地址。
        logic [31:0] output_address; // 当前strip下一RGB写行的DDR首地址。
    } row_addresses_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 激活读请求，输入与X0互斥。
        logic valid; // 当前独占读客户的字节区间命令。
        logic [31:0] address; // 十六字节对齐DDR读地址。
        logic [15:0] length; // 有效读字节数。
        logic data_ready; // 独占读客户可接收当前128位拍。
    } activation_read_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // 激活写命令及已预留的burst数据。
        logic valid; // 写字节区间命令。
        logic [31:0] address; // 十六字节对齐首地址。
        logic [15:0] length; // 有效字节数1..65535。
        logic data_valid; // 已预留的burst数据流。
        logic [127:0] data; // 十六字节数据，等待时保持。
        logic [15:0] keep; // 部分末拍字节选择。
    } activation_write_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // X0低拍捕获授权，数据复用host读拍。
        logic write; // 帧X0低拍复用模型装载器既有128位寄存器。
    } scratch_request_t; // 本组位序由字段定义，不使用位置拼接。

    typedef struct packed { // host返回的DDR响应、权重写流与空闲状态。
        read_response_t read; // DDR读命令握手、128位返回拍和完成事件。
        write_response_t write; // DDR写命令握手、W消费和B完成事件。
        model_response_t model; // 整表权重装载的接受与完成事件。
        weight_write_t weights; // 主表40位项写流，地址与数据同valid保持。
        host_aux_t aux; // 总线静止状态与共享低拍寄存器。
    } host_transport_t; // 接口只描述连线。

    typedef struct packed { // 任务控制发布的帧配置、当前行描述符和授权。
        frame_config_t layout; // 帧命令锁存的尺寸、DDR基址与行跨度。
        row_command_t row; // 行描述符，接受后保持至计算和DDR共同完成。
        input_command_t input_row; // 当前Stem任务所需的两条RGB输入行。
        x0_command_t x0; // 当前主体行的X0读回区间及C中心范围。
        weight_hint_t weight_hint; // 当前行执行期间可准备的下一模型层。
        strip_context_t strip; // 当前strip范围、边界脉冲及D物理保存布局。
        phase_control_t phase; // 帧抢占及安全工作状态清除。
        dispatch_t dispatch; // 任务控制对内部工作模块的授权。
        row_addresses_t addresses; // 四条顺序DDR流的当前行首地址。
    } frame_context_t; // 接口只描述连线。

    typedef struct packed { // 计算与片上存储的状态和向DMA返回的数据。
        feedback_row_t row; // 行定序器的配置、issue节拍及结果坐标。
        feedback_window_t window; // 抽头读请求、装填写使能及窗口完成状态。
        feedback_residual_t residual; // 按实际issue对齐的残差读请求。
        feedback_engine_t engine; // 行引擎的权重提交、窗口消费及计算结果。
        feedback_memory_t memory; // 片上存储的握手、读返回及结果整理接口。
        feedback_descriptor_t descriptor; // 固定模型的合法层检查与权重地址。
    } compute_feedback_t; // 接口只描述连线。

    typedef struct packed { // DMA与RGB配对对任务控制、片上存储的请求。
        feedback_input_dma_t input_dma; // RGB输入分段DMA的状态及D段暂存写流。
        feedback_input_pair_t input_pair; // 上行段读取和上下行像素配对接口。
        feedback_output_dma_t output_dma; // C输出队列、共享RGB前缀及行提交状态。
        feedback_x0_dma_t x0_dma; // X0行读回的状态及原子C/D写流。
    } transfer_feedback_t; // 接口只描述连线。

    typedef struct packed { // DDR激活读写及共享低拍寄存器捕获请求。
        activation_read_t read; // 激活读请求，输入与X0互斥。
        activation_write_t write; // 激活写命令及已预留的burst数据。
        scratch_request_t scratch; // X0低拍捕获授权，数据复用host读拍。
    } activation_request_t; // 接口只描述连线。
endpackage // 系统接口类型结束。
