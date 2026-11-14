cmake_minimum_required(VERSION 3.16)

include(${CMAKE_CURRENT_LIST_DIR}/../../cmake/version.cmake)

set(CMAKE_CXX_STANDARD 17)

project(
  tracy-metal4-test
  LANGUAGES C CXX OBJCXX
  VERSION ${TRACY_VERSION_STRING})

file(GENERATE OUTPUT .gitignore CONTENT "*")
set(CMAKE_COLOR_DIAGNOSTICS ON)

option(TRACY_ENABLE "Enable profiling" ON)

add_subdirectory(${CMAKE_CURRENT_LIST_DIR}/../.. client/)

add_executable(tracy-metal4-test test.mm)
target_compile_options(tracy-metal4-test PRIVATE -fobjc-arc)
target_link_libraries(tracy-metal4-test TracyClient "-framework Metal" "-framework Foundation")
