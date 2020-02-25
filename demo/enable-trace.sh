#! /bin/sh

file=trace.csv

if [ $# -eq 1 ]; then
    file="$1"
fi

if [ x"$NCS_DIR" = x ]; then
    echo "Need \$NCS_DIR to be set"
    exit 1
fi

# Load configuration that enables CSV progress tracing
ncs_load -lm -FC <<EOF
progress trace csv
 destination file $file
 destination format csv
 enabled
 verbosity very-verbose
!
EOF

res=$?

# Show the result
ncs_load -FC -p /progress

exit $res
