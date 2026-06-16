.PHONY: build run dump test package clean

build:        ## Debug build
	swift build

run:          ## Run the app (menu bar)
	swift run CodingBar

dump:         ## Print the computed Snapshot as JSON (verify the data layer)
	swift run CodingBar --dump-json

test:         ## Runnable self-test (XCTest needs Xcode; this works on CLT)
	swift run CodingBar --self-test

package:      ## Build dist/CodingBar.app
	./Scripts/package.sh

clean:
	rm -rf .build dist
