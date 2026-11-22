# Compatibility config: old state-observation installs only pkg-config
# metadata but mc_rtc revision looks for a CMake imported target
if(NOT TARGET state-observation::state-observation)
  add_library(state-observation::state-observation STATIC IMPORTED)
  set_target_properties(state-observation::state-observation PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/../../../lib/libstate-observation.a"
    INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}/../../../include"
  )
endif()
