# /root/.profile — runs after login

# Run first-boot setup wizard if OVF init didn't complete
if [ -x /usr/local/bin/abr-setup-wizard ]; then
    /usr/local/bin/abr-setup-wizard
fi

# Show the appliance console menu
if [ -x /usr/local/bin/abr-console ]; then
    exec /usr/local/bin/abr-console
fi
