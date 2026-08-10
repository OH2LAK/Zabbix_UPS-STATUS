#!/bin/bash
ups=$1

# Map textual ups.status to same numeric codes as the original script
map_status() {
    case "$1" in
        "OL")           echo 1 ;;
        "OB")           echo 2 ;;
        "LB")           echo 3 ;;
        "RB")           echo 4 ;;
        "CHRG")         echo 5 ;;
        "DISCHRG")      echo 6 ;;
        "BYPASS")       echo 7 ;;
        "CAL")          echo 8 ;;
        "OFF")          echo 9 ;;
        "OVER")         echo 10 ;;
        "TRIM")         echo 11 ;;
        "BOOST")        echo 12 ;;
        "OL CHRG")      echo 13 ;;
        * )             echo 0 ;;
    esac
}

output=$(/bin/upsc "$ups" 2>&1 | grep -v SSL)

json="{"
first=1
while IFS=': ' read -r k v; do
    [ -z "$k" ] && continue
    # re-join in case value itself contained ": "
    val=$(echo "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')
    key=$(echo "$k" | sed 's/\\/\\\\/g; s/"/\\"/g')

    if [ "$first" -eq 0 ]; then
        json="${json},"
    fi
    json="${json}\"${key}\":\"${val}\""
    first=0

    if [ "$key" = "ups.status" ]; then
        code=$(map_status "$val")
        json="${json},\"ups.status.code\":\"${code}\""
    fi
done <<< "$output"
json="${json}}"

echo "$json"
