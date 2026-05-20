# /root/.profile

# Run first-boot setup wizard if OVF init hasn't completed
if [ ! -f /var/lib/asbuiltreport/.ovf-init-done ] && \
   [ -x /usr/local/bin/abr-setup-wizard ]; then
    /usr/local/bin/abr-setup-wizard
fi

# Launch console menu on tty1 only, and only once (not recursively)
if [ "$(tty)" = "/dev/tty1" ] && \
   [ -z "$ABR_CONSOLE_RUNNING" ] && \
   [ -x /usr/local/bin/abr-console ]; then
    export ABR_CONSOLE_RUNNING=1
    /usr/local/bin/abr-console
fi
