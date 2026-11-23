cmake_minimum_required(VERSION 3.16)
project(qgmodule LANGUAGES C CXX)

set(QG_MODULE_ENGINE_SOURCES
  qgmodule_engine.cpp
  quickjs/quickjs.c
  quickjs/dtoa.c
  quickjs/libregexp.c
  quickjs/libunicode.c
  quickjs/cutils.c
)
add_library(qgmodule SHARED qgmodule_napi.cpp ${QG_MODULE_ENGINE_SOURCES})
file(STRINGS quickjs/VERSION QUICKJS_VERSION LIMIT_COUNT 1)
target_compile_definitions(qgmodule PRIVATE _GNU_SOURCE CONFIG_VERSION="${QUICKJS_VERSION}")
target_compile_options(qgmodule PRIVATE -fvisibility=hidden)
target_compile_features(qgmodule PRIVATE cxx_std_17)
target_link_libraries(qgmodule PRIVATE libace_napi.z.so m)

option(QG_MODULE_NATIVE_TEST "Build the standalone module runtime checks" OFF)
if(QG_MODULE_NATIVE_TEST)
  add_executable(qgmodule_test tests/qgmodule_test.cpp ${QG_MODULE_ENGINE_SOURCES})
  target_include_directories(qgmodule_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_definitions(qgmodule_test PRIVATE _GNU_SOURCE CONFIG_VERSION="${QUICKJS_VERSION}")
  target_compile_features(qgmodule_test PRIVATE cxx_std_17)
  target_link_libraries(qgmodule_test PRIVATE m)
endif()
