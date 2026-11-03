#include "proj_menu.h"


#include "menu.h"

#include "lab2_test.h"
#ifdef TFLM_MODEL_ENABLED
#include "conv_test.h"
#endif

namespace {

const MenuItem kLabItems[] = {
    MENU_ITEM('t', "Lab2 set tests", do_lab2_set_test),
    MENU_ITEM('r', "Lab2 random tests", do_lab2_random_test),
#ifdef TFLM_MODEL_ENABLED
    MENU_ITEM('c', "Convolution golden tests", conv_address_aligned_test),
#endif
    MENU_END,
};

const Menu kLabMenu = {
    "Lab 2",
    "lab2",
    kLabItems,
};

}  // namespace

void lab_menu_run(void) { menu_run(&kLabMenu); }
