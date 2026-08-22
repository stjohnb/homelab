FROM alpine:3.21

LABEL org.opencontainers.image.source=https://github.com/St-John-Software/fleet-infra

RUN apk add --no-cache arpwatch curl jq && \
    rm -f /usr/sbin/sendmail && \
    ln -s /usr/local/bin/notify-slack.sh /usr/sbin/sendmail && \
    mkdir -p /usr/share/arpwatch && \
    curl -fsSL --retry 5 --retry-delay 5 \
        -o /tmp/oui.txt https://standards-oui.ieee.org/oui/oui.txt && \
    awk '/\(hex\)/ { \
        mac = tolower($1); gsub(/-/, ":", mac); \
        idx = index($0, "(hex)"); \
        vendor = substr($0, idx + 5); \
        sub(/^[ \t]+/, "", vendor); \
        sub(/[ \t\r]+$/, "", vendor); \
        if (vendor != "" && mac ~ /^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}$/) \
            print mac "\t" vendor; \
    }' /tmp/oui.txt | sort -u > /usr/share/arpwatch/ethercodes.dat && \
    rm /tmp/oui.txt && \
    test -s /usr/share/arpwatch/ethercodes.dat && \
    wc -l /usr/share/arpwatch/ethercodes.dat
