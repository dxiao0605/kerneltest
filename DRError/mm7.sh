#!/bin/bash

# Function to print usage
usage() {
  echo "Usage: $0 -o <sender> -r <recipient> [-r <recipient> ...] -V <vaspid> -v <vasid> -u url -s <subject> -B <basic authentication>"
  echo "Options:"
  echo "  -o, Sender of the message"
  echo "  -r, Recipient of the message (can be given multiple times for multiple recipients)"
  echo "  -V, VAS Provider"
  echo "  -v, VAS id"
  echo "  -u, MM7 Url"
  echo "  -s, MMS Subject"
  exit 1
}

# Parse options
while getopts ":o:r:V:v:u:s:B:" opt; do
  case $opt in
    o) sender="$OPTARG" ;;
    r) recipients+=("$OPTARG") ;;
    V) vaspid="$OPTARG" ;;
    v) vasid="$OPTARG" ;;
    u) url="$OPTARG" ;;
    s) subject="$OPTARG" ;;
    B) basic_authetication="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

# Check if required options are provided
if [[ -z "$sender" || ${#recipients[@]} -eq 0 || -z "$vaspid" || -z "$vasid" || -z "$subject" || -z "$url" ]]; then
  echo "Error: Missing required options."
  usage
fi

# Additional validation or processing can be added here

echo "Sender: $sender"
echo "Recipients: ${recipients[*]}"
echo "VAS Provider: $vaspid"
echo "VASID: $vasid"
echo "Subject: $subject"
echo "URL: $url"

# File path
file_path="t_multipart_jpeg.xml"
recipients_block="t_recipients_block.xml"

# Build the recipients XML block (one <To> per recipient)
> "$recipients_block"
for rcpt in "${recipients[@]}"; do
  {
    echo "        <To>"
    echo "          <Number>${rcpt}</Number>"
    echo "        </To>"
  } >> "$recipients_block"
done

cp multipart_jpeg.xml "$file_path"

# Use sed to replace the string in the file
sed -i "s/J_SENDER/$sender/g" "$file_path"
sed -i "s/J_VAS_PROVIDER/$vaspid/g" "$file_path"
sed -i "s/J_VAS_ID/$vasid/g" "$file_path"
sed -i "s/J_SUBJECT/$subject/g" "$file_path"

# Multi-line placeholder: insert the recipients block, then delete the placeholder line
sed -i "/J_RECIPIENTS_BLOCK/r $recipients_block" "$file_path"
sed -i "/J_RECIPIENTS_BLOCK/d" "$file_path"

if [ -n "$basic_authetication" ]; then
   wget $url --post-file $file_path --header 'Content-type:multipart/related;boundary="----=_NextPart_1067088750";type=text/xml;start="mm7_msg"' --header 'Authorization: Basic $basic_authetication' -O mm7_submit.txt
else
   wget $url --post-file $file_path --header 'Content-type:multipart/related;boundary="----=_NextPart_1067088750";type=text/xml;start="mm7_msg"' -O mm7_submit.txt
fi

unlink "$file_path"
unlink "$recipients_block"