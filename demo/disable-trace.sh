#! /bin/sh

if [ x"$NCS_DIR" = x ]; then
    echo "Need \$NCS_DIR to be set"
    exit 1
fi

# Load configuration that disables CSV progress tracing
ncs_load -lm -FC <<EOF
progress trace csv
 disabled
!
EOF

res=$?

# Show the result
ncs_load -FC -p /progress

exit $res
