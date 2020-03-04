
all: progress2span.beam

# Generate JSON files from .csv progress traces
%.json: progress2span.beam %.csv
	escript $^ $@

#
# To upload spans, post them to http://127.0.0.1:9411/api/v2/spans
# with Content-Type: application/json
#
%.upload: %.json
	curl -v -H 'Content-Type: application/json' \
	    http://127.0.0.1:9411/api/v2/spans -d @- < $<

# Compile the Erlang script
%.beam: %.erl
	erlc $<

clean:
	rm -f *.beam

distclean: clean
	rm -f zipkin.*
	cd demo && $(MAKE) -k clean || true


#
# Zipkin related convenience targets
#
CWD = $(shell pwd)

## Start a local copy of Zipkin
zipkin: zipkin.jar
	cd /tmp && java -jar $(CWD)/zipkin.jar

## Seems unsafe? It's what the kids do these days...
zipkin.jar:
	curl https://zipkin.io/quickstart.sh | bash -s

## Or just run it in docker
zipkin.docker:
	docker run -d -p 9411:9411 openzipkin/zipkin
