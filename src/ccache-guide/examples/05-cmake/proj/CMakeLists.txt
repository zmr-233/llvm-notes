cmake_minimum_required(VERSION 3.20)
project(ccache_cmake_demo C CXX)

# 写法 C 的开关：模仿 LLVM_CCACHE_BUILD，用全局属性 RULE_LAUNCH_COMPILE 而不是 *_COMPILER_LAUNCHER
option(DEMO_RULE_LAUNCH "use RULE_LAUNCH_COMPILE" OFF)
set(DEMO_RULE_LAUNCH_VALUE "" CACHE STRING "text prepended to every compile command")
if(DEMO_RULE_LAUNCH)
  set_property(GLOBAL PROPERTY RULE_LAUNCH_COMPILE "${DEMO_RULE_LAUNCH_VALUE}")
endif()

add_library(demo STATIC src/lib.c)
target_include_directories(demo PUBLIC src)

add_executable(app src/main.cpp)
target_link_libraries(app PRIVATE demo)

# 子工程：独立的一次 cmake configure + build，发生在父工程 build 期间。
# 它不继承父工程的缓存变量——这正是 LLVM 的 runtimes 构建会遇到的情形。
include(ExternalProject)
ExternalProject_Add(child
  SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/child
  BINARY_DIR ${CMAKE_CURRENT_BINARY_DIR}/child-build
  INSTALL_COMMAND "")
