map(select(type=="object") |
  select(.event_type=="alert")) | sort_by(.timestamp)[] |
  [.timestamp, .src_ip, .dest_ip, (.dest_port // ""),
   (.alert.signature // "")] | @tsv