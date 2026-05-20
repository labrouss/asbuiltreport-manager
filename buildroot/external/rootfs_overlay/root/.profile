# /root/.profile — runs on login

# First-boot setup wizard (runs once, skipped after sentinel is set)
if [ -x /usr/local/bin/abr-setup ]; then
    /usr/local/bin/abr-setup
fi

# Appliance console menu (tty1 only, no recursion)
if [ "$(tty)" = "/dev/tty1" ] && \
   [ -z "$ABR_CONSOLE_RUNNING" ] && \
   [ -x /usr/local/bin/abr-console ]; then
    export ABR_CONSOLE_RUNNING=1
    /usr/local/bin/abr-console
fi
