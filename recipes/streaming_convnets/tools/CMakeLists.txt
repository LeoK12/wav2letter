cmake_minimum_required(VERSION 3.10)

add_executable(
    StreamingTDSModelConverter
    StreamingTDSModelConverter.cpp
  )

target_include_directories(
    StreamingTDSModelConverter
    PRIVATE
    ${PROJECT_SOURCE_DIR}
  )

target_link_libraries(
  StreamingTDSModelConverter
  PRIVATE
  flashlight::flashlight-app-asr
  )
