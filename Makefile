
all: progress2span.beam

%.beam: %.erl
	erlc $<

%.json: progress2span.beam %.csv
	escript $^ $@

#
# To upload spans, post them to http://127.0.0.1:9411/api/v2/spans
# with Content-Type: application/json
#
%.upload: %.json
	curl -v -H 'Content-Type: application/json' \
	    http://127.0.0.1:9411/api/v2/spans -d @- < $<

clean:
	rm -f *.beam


distclean:
	rm -f zipkin.*



CWD = $(shell pwd)

## Start a local copy of Zipkin
zipkin: zipkin.jar
	cd /tmp && java -jar $(CWD)/zipkin.jar

## Seems unsafe? It's what the kids do these days...
zipkin.jar:
	curl https://zipkin.io/quickstart.sh | bash -s
