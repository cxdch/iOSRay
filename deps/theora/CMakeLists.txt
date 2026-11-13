# У libtheora нет CMake — собираем переносимый C-вариант без ассемблера.
# Кодировщик не нужен (движок только проигрывает .ogm), поэтому theoraenc — заглушка encoder_disabled.c.
cmake_minimum_required(VERSION 3.16)
project(theora C)
set(SRC "${THEORA_SOURCE_DIR}/lib")
set(DEC_SOURCES
    ${SRC}/apiwrapper.c ${SRC}/bitpack.c ${SRC}/decapiwrapper.c ${SRC}/decinfo.c ${SRC}/decode.c
    ${SRC}/dequant.c ${SRC}/fragment.c ${SRC}/huffdec.c ${SRC}/idct.c ${SRC}/info.c
    ${SRC}/internal.c ${SRC}/quant.c ${SRC}/state.c)
find_package(Ogg REQUIRED)
foreach(lib theoradec theoraenc theora)
    if(lib STREQUAL theoraenc)
        add_library(${lib} STATIC ${SRC}/encoder_disabled.c ${SRC}/info.c ${SRC}/internal.c ${SRC}/state.c ${SRC}/quant.c ${SRC}/fragment.c ${SRC}/idct.c)
    elseif(lib STREQUAL theora)
        add_library(${lib} STATIC ${DEC_SOURCES} ${SRC}/encoder_disabled.c)
    else()
        add_library(${lib} STATIC ${DEC_SOURCES})
    endif()
    target_include_directories(${lib} PRIVATE "${THEORA_SOURCE_DIR}/include" "${SRC}")
    target_link_libraries(${lib} PRIVATE Ogg::ogg)
    install(TARGETS ${lib} ARCHIVE DESTINATION lib)
endforeach()
install(DIRECTORY "${THEORA_SOURCE_DIR}/include/theora" DESTINATION include)
