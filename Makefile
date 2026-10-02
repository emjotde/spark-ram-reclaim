.PHONY: test preflight build key sign

test:
	python3 -m unittest discover -s tests -v
	bash -n scripts/build.sh scripts/modules.sh spark-reclaim
	./spark-reclaim --help >/dev/null
	./spark-reclaim reclaim --dry-run | grep -q 'verify MemTotal and CUDA coverage'

preflight:
	python3 tools/preflight.py

build:
	bash scripts/build.sh

key:
	bash scripts/modules.sh key

sign:
	bash scripts/modules.sh sign
