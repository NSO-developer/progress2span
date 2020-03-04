# Progress -> Span

A script that converts progress traces taken from NSO to trace spans in JSON format that can be consumed by tools like [Zipkin](https://zipkin.io)

# Quickstart

Start by installing Zipkin and Erlang (see Prerequisites below).

Enable progress trace to a CSV file in your NSO installation.

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

Do some activity that you want to trace...

...and then copy the trace file

    > cp .../logs/trace.csv .

Generate a JSON file

    > make trace.json

Start zipkin (in a separate terminal)

    > make zipkin

Upload the trace file

    > make trace.upload

Browse the Zipkin server

    > open "http://127.0.0.1:9411/zipkin/"


# Even Quicker Start

Make sure you have the Prerequisites, as well as download a copy of the IOS NED. Unpack the NED somewhere (for example in the demo directory). Then you can do the following:

    > cd demo
    > make IOS_NED=./cisco-ios-cli-6.45

(But make sure to replace `./cisco-ios-cli-6.45` with the real path to your IOS NED)

    > make start
    > make enable
    > make cli
    admin@ncs# devices sync-from
    admin@ncs# exit
    > cp ncs-runtime/logs/trace.csv ..
    > cd ..
    > make trace.json

Now start zipkin (in a separate terminal)

    > make zipkin

Then back to the first terminal, and upload the trace

    > make trace.upload
    > open "http://127.0.0.1:9411/zipkin/"

Hit the search button in the UI and your trace should show up (may have to search back in time).

Here is a quick screencast of what it could look like:

![Screenshot](demo/screencast.gif)


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
