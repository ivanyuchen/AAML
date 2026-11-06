#include "proj_menu.h"

#include "menu.h"

extern void run_logistic_test();
extern void run_transpose_test();

namespace {

const MenuItem kLabItems[] = {
    MENU_ITEM('l', "run logistic test", run_logistic_test),
    MENU_ITEM('t', "run transpose test", run_transpose_test),
    MENU_END,
};

const Menu kLabMenu = {
    "Lab : Self Test",
    "lab",
    kLabItems,
};

}  // namespace

void lab_menu_run(void) { menu_run(&kLabMenu); }
