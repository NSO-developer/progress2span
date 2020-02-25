# Progress -> Span

This script can convert progress traces taken from NSO and convert them to trace spans which can be consumed by tools like [Zipkin](https://zipkin.io)

# Quickstart

1. Install Zipkin and Erlang (see Prerequisites below)

2. Enable progress trace to a CSV file in your NSO installation

    admin@ncs# config
    Entering configuration mode terminal
    admin@ncs(config)# unhide debug
    admin@ncs(config)# progress trace csv destination file trace.csv format csv
    admin@ncs(config-trace-csv)# enabled
    admin@ncs(config-trace-csv)# verbosity very-verbose
    admin@ncs(config-trace-csv)# commit
    Commit complete.
    admin@ncs(config-trace-csv)# exit
    admin@ncs(config)# exit

3. Do some activity that you want to trace...

4. Copy the trace file

    > cp .../logs/trace.csv .

5. Generate a JSON file

    > make trace.json

6. Start zipkin (in a separate terminal)

    > make zipkin

7. Upload the trace file

    > make trace.upload

8. Browse the Zipkin server

    > open "http://127.0.0.1:9411/zipkin/"


# Prerequisites

## [Zipkin](https://zipkin.io)

You can run [Zipkin](https://zipkin.io) in a docker container, or from a standalone Java jar, as documented here https://zipkin.io/pages/quickstart.html

If you are brave you can just do

    make zipkin.jar


## [Erlang](https://erlang.org/)

You need a fairly recent version of [Erlang](https://erlang.org/) (Erlang/OTP 21 or newer) in order to run the script. Note that this is newer than what is shipped with any current NSO release, so you will have to install a version of Erlang locally. For example on MacOS using [MacPorts](https://www.macports.org):

    port install erlang

or using [Homebrew](https://brew.sh)

    brew install erlang

On Ubuntu and others:

    apt install erlang

On some distributions you get too old releases, in that case you can [download a more recent and pre-built Erlang package from Erlang Solutions](https://www.erlang-solutions.com/resources/download.html).

*Note* if you do not have a new enough Erlang installed you will get an error message when you try to run the script, like this:

    Error: Need Erlang/OTP 21 or newer to run


## Other

The Makefile uses `curl` to upload the JSON traces.

An NSO installation to get progress trace files from. See NSO documentation for full details, but note that you need `<hide-group><name>debug</name></hide-group>` in your `ncs.conf` in order to be able to enable progress tracing.
