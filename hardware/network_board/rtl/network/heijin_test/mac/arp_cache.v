module arp_cache
       (
         input                clk ,
         input                rst_n ,
         
         input                arp_found,
         input                tx_in_progress,
         input  [31:0]        arp_rec_source_ip_addr,
         input  [47:0]        arp_rec_source_mac_addr,
         
         input  [31:0]        destination_ip_addr,
         output reg [47:0]    destination_mac_addr,
         
         output wire          mac_not_exist
       ) ;
       
parameter [29:0] CACHE_TIMEOUT_CYCLES = 30'd750_000_000; // 30 s at 25 MHz
reg [79:0]  arp_cache ;
reg         cache_valid;
reg [29:0]  cache_age;
wire        source_mac_valid = (arp_rec_source_mac_addr != 48'd0) &&
                               (arp_rec_source_mac_addr != 48'hff_ff_ff_ff_ff_ff) &&
                               !arp_rec_source_mac_addr[40];

//init arp cache
always @(posedge clk or negedge rst_n)
  begin
    if (~rst_n)
      begin
        arp_cache  <= {32'd0, 48'hff_ff_ff_ff_ff_ff};
        cache_valid <= 1'b0;
        cache_age <= 30'd0;
      end
    else if (arp_found && arp_rec_source_ip_addr == destination_ip_addr && source_mac_valid)
      begin
        arp_cache <= {arp_rec_source_ip_addr, arp_rec_source_mac_addr};
        cache_valid <= 1'b1;
        cache_age <= 30'd0;
      end
    else if (cache_valid && cache_age >= CACHE_TIMEOUT_CYCLES - 1'b1)
      begin
        cache_valid <= 1'b0;
        cache_age <= 30'd0;
      end
    else if (cache_valid)
      cache_age <= cache_age + 1'b1;
  end
  
always @(posedge clk or negedge rst_n)
  begin
    if (~rst_n)
      destination_mac_addr  <= 48'hff_ff_ff_ff_ff_ff ;
    // Hold the resolved L2 address for the entire active Ethernet frame.
    // Expiry still blocks future packets through mac_not_exist; changing the
    // byte source mid-frame would otherwise splice a partial destination MAC.
    else if (!tx_in_progress) begin
      if (cache_valid && destination_ip_addr == arp_cache[79:48])
        destination_mac_addr  <= arp_cache[47:0] ;
      else
        destination_mac_addr  <= 48'hff_ff_ff_ff_ff_ff ;
    end
  end
  
// Admission must see expiry/address changes immediately. A delayed flag lets
// a new packet claim the unresolved route for one extra clock.
assign mac_not_exist = !cache_valid || destination_ip_addr != arp_cache[79:48];
  
endmodule
