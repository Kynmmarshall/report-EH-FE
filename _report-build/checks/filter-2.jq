select(type=="object") |
  select(.event_type=="alert" and .src_ip=="192.168.50.100") |
  select((.alert.signature // "") | test("nmap|scan"; "i")) |
  {timestamp, src_ip, dest_ip, dest_port,
   signature: .alert.signature}