.PHONY: build run dump test package icon clean

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

icon:         ## Regenerate Scripts/AppIcon.icns from the DIRECTION 03 renderer
	swift run CodingBar --render-appicon /tmp/CodingBar.iconset
	iconutil -c icns /tmp/CodingBar.iconset -o Scripts/AppIcon.icns
	rm -rf /tmp/CodingBar.iconset
	@echo "✓ Scripts/AppIcon.icns"

clean:
	rm -rf .build dist
