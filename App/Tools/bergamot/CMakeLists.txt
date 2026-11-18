# Wraps bergamot-translator with mm2t's C API. Driven by App/Tools/build-bergamot.sh.
cmake_minimum_required(VERSION 3.16)
project(mm2t_bergamot CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(BERGAMOT_SOURCE_DIR "" CACHE PATH "Patched bergamot-translator checkout")
if(NOT EXISTS "${BERGAMOT_SOURCE_DIR}/CMakeLists.txt")
  message(FATAL_ERROR "BERGAMOT_SOURCE_DIR must point at a bergamot-translator checkout")
endif()

add_subdirectory(${BERGAMOT_SOURCE_DIR} bergamot EXCLUDE_FROM_ALL)

add_library(mm2t_bergamot STATIC mm2t_bergamot.cpp)
target_include_directories(mm2t_bergamot PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(mm2t_bergamot PUBLIC bergamot-translator)

# Links exactly what the app links; the script reads this link line to know which archives to merge.
add_executable(mm2t-bergamot-cli cli.c)
target_link_libraries(mm2t-bergamot-cli PRIVATE mm2t_bergamot)
