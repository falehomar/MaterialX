#!/bin/bash

# Get the directory of the script
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

LIB_PATH="$DIR/build/lib"
JAR_PATH="$DIR/build/source/MaterialXView/MaterialXViewer.jar"

if [ ! -f "$JAR_PATH" ] || [ ! -d "$LIB_PATH" ]; then
    echo "Error: Could not find build artifacts."
    echo "Expected Jar: $JAR_PATH"
    echo "Expected Lib: $LIB_PATH"
    exit 1
fi

# Run the viewer passing any additional arguments
java -XstartOnFirstThread \
     --enable-native-access=ALL-UNNAMED \
     -Dmaterialx.lib.path="$LIB_PATH" \
     -jar "$JAR_PATH" "$@"
