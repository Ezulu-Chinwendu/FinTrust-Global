#!/bin/bash
# scripts/build.sh

set -e  # Exit immediately if any command fails

echo 'í³¦ Building Lambda package...'

cd lambda

# Install Node.js dependencies
npm install

# Create zip file (AWS Lambda requires a zip)
zip -r function.zip handler.js node_modules package.json

echo 'âœ… Lambda package built: lambda/function.zip'

cd ..

