# CMake generated Testfile for 
# Source directory: /home/dev/graphdb/FilterVectorCode_refactor/UNG/codes/third_party/CRoaring
# Build directory: /home/dev/graphdb/FilterVectorCode_refactor/UNG/build-cpu/croaring_build
# 
# This file includes the relevant testing commands required for 
# testing this directory and lists subdirectories to be tested as well.
add_test(amalgamate_demo "amalgamate_demo")
set_tests_properties(amalgamate_demo PROPERTIES  _BACKTRACE_TRIPLES "/home/dev/graphdb/FilterVectorCode_refactor/UNG/codes/third_party/CRoaring/CMakeLists.txt;146;add_test;/home/dev/graphdb/FilterVectorCode_refactor/UNG/codes/third_party/CRoaring/CMakeLists.txt;0;")
add_test(amalgamate_demo_cpp "amalgamate_demo_cpp")
set_tests_properties(amalgamate_demo_cpp PROPERTIES  _BACKTRACE_TRIPLES "/home/dev/graphdb/FilterVectorCode_refactor/UNG/codes/third_party/CRoaring/CMakeLists.txt;159;add_test;/home/dev/graphdb/FilterVectorCode_refactor/UNG/codes/third_party/CRoaring/CMakeLists.txt;0;")
subdirs("../_deps/cmocka-build")
subdirs("src")
subdirs("benchmarks")
subdirs("tests")
