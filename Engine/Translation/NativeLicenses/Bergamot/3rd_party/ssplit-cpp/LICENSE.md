# LICENSE TERMS

This repository is covered by two licenses:

1. The C++ code and code related to the build system (cmake) is under the APACHE 2.0 license:
   ```
   Copyright 2019 University of Edinburgh

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
   ```
   
2. The files in the directory `nonbreaking_prefixes` were copied from https://github.com/moses-smt/mosesdecoder/tree/master/scripts/share/nonbreaking_prefixes 
   and are thus distributed under the [LGPL 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.en.html).
   On a technical note: these files are read by the compiled library and not compiled into the library. 
   You can replace them by your own custom files if the LGPL is an issue for your use case.
