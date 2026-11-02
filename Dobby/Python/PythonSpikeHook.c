// #482 spike trigger, Debug builds only: with DOBBY_PYTHON_SPIKE set in the environment the
// app runs dobby_python_spike (PythonRuntime.swift) before main and exits, so the spike never
// opens a window, a web view or any app storage.
#ifdef DEBUG
#include <stdlib.h>

void dobby_python_spike(void);

__attribute__((constructor)) static void dobby_python_spike_hook(void) {
    if (getenv("DOBBY_PYTHON_SPIKE")) dobby_python_spike();
}
#endif
