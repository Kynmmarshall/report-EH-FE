
  inputs | input_line_number as $line | . as $raw |
  try ($raw | fromjson)
  catch {parse_error: ., source_line: $line}
