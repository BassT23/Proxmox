#!/usr/bin/env bash

echo "Listing all LXC containers..."
pct list

read -p "Enter the LXC IDs to update (comma-separated): " LXC_IDS

IFS=',' read -ra ID_ARRAY <<< "$LXC_IDS"

for LXC_ID in "${ID_ARRAY[@]}"; do
    LXC_ID=$(echo "$LXC_ID" | xargs)

    if ! pct list | awk '{print $1}' | grep -q "^$LXC_ID$"; then
        echo "❌ Error: LXC ID $LXC_ID not found! Skipping..."
        continue
    fi

    STATUS=$(pct list | awk -v id="$LXC_ID" '$1 == id {print $2}')
    if [[ "$STATUS" != "running" ]]; then
        read -p "LXC $LXC_ID is not running. Start it? (y/n): " START_LXC
        if [[ "$START_LXC" == "y" ]]; then
            echo "Starting LXC $LXC_ID..."
            pct start "$LXC_ID"
            sleep 5
        else
            echo "Skipping LXC $LXC_ID."
            continue
        fi
    fi

    echo "Checking for 'community-scripts' inside LXC $LXC_ID..."
    if ! pct exec "$LXC_ID" -- grep -q "community-scripts" /usr/bin/update 2>/dev/null; then
        echo "❌ 'community-scripts' not found in /usr/bin/update. Skipping LXC $LXC_ID."
        continue
    fi

    echo "Checking for expect inside LXC $LXC_ID..."
    pct exec "$LXC_ID" -- sh -c '
        if ! command -v expect >/dev/null 2>&1; then
            echo "Installing expect..."
            if [ -f /etc/alpine-release ]; then
                apk add --no-cache expect >/dev/null
            elif [ -f /etc/debian_version ]; then
                apt update && apt install -y expect >/dev/null
            else
                echo "Unsupported OS. Please install expect manually."
                exit 1
            fi
        fi
    '

    echo "Running update inside LXC $LXC_ID..."
    pct exec "$LXC_ID" -- stdbuf -oL -eL expect <<EOF | grep -v "whiptail"
set timeout 3
spawn update
expect "Choose an option:"
send "2\r"
expect "<Ok>"
send "\r"
expect eof
EOF

    echo "✅ Update process completed for LXC $LXC_ID."
done

echo "🎉 All selected LXC updates are done!"
