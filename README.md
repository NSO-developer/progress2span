# Progress -> Span

This script can convert progress traces taken from NSO and convert them to trace spans which can be consumed by tools like [Zipkin](https://zipkin.io)


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

*Note* if you don't have a new enough Erlang installed you will get an error message when you try to run the script, like this:

    Error: Need Erlang/OTP 21 or newer to run
