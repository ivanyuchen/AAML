#include "proj_menu.h"

#include "accelerator_test.h"
#include "conv_test.h"
#include "menu.h"

namespace {

const MenuItem kLabItems[] = {
    MENU_ITEM('a', "Accelerator AXI Aligned Test", accelerator_test),
    MENU_ITEM('b', "Accelerator AXI Misaligned Test", accelerator_misaligned_test),
    MENU_ITEM('c', "Basic Convolution Test", conv_address_aligned_test),
    MENU_END,
};

const Menu kLabMenu = {
    "Lab 1: Aligned AXI Data on SIMD",
    "lab1",
    kLabItems,
};

}  // namespace

void lab_menu_run(void) { menu_run(&kLabMenu); }
