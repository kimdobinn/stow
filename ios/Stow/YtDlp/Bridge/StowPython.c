#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>

#include <stdlib.h>
#include <string.h>

#include "StowPython.h"

static StowPyEventHandler stow_on_event;
static StowPyCancelCheck stow_is_cancelled;
static StowJSEvaluator stow_evaluate_js;
static PyObject *stow_submit_function;

// MARK: - The _stow module (Python -> Swift)

static PyObject *stow_emit(PyObject *self, PyObject *args) {
    long long call_id;
    const char *kind;
    const char *payload;
    Py_ssize_t length;
    if (!PyArg_ParseTuple(args, "Lss#", &call_id, &kind, &payload, &length)) return NULL;
    if (stow_on_event) stow_on_event((int64_t)call_id, kind, payload, (int64_t)length);
    Py_RETURN_NONE;
}

static PyObject *stow_cancelled(PyObject *self, PyObject *args) {
    long long call_id;
    if (!PyArg_ParseTuple(args, "L", &call_id)) return NULL;
    if (stow_is_cancelled && stow_is_cancelled((int64_t)call_id)) Py_RETURN_TRUE;
    Py_RETURN_FALSE;
}

static PyObject *stow_js_eval(PyObject *self, PyObject *args) {
    const char *script;
    if (!PyArg_ParseTuple(args, "s", &script)) return NULL;
    if (!stow_evaluate_js) {
        PyErr_SetString(PyExc_RuntimeError, "no JavaScript runtime");
        return NULL;
    }
    char *output = NULL;
    char *error = NULL;
    // Solving YouTube's challenges takes a while; other Python threads keep running meanwhile.
    Py_BEGIN_ALLOW_THREADS
    output = stow_evaluate_js(script, &error);
    Py_END_ALLOW_THREADS
    if (!output) {
        PyErr_SetString(PyExc_RuntimeError, error ? error : "JavaScript failed");
        free(error);
        return NULL;
    }
    PyObject *result = PyUnicode_FromString(output);
    free(output);
    free(error);
    return result;
}

static PyMethodDef stow_methods[] = {
    {"emit", stow_emit, METH_VARARGS, "emit(call_id, kind, payload): report to Swift"},
    {"cancelled", stow_cancelled, METH_VARARGS, "cancelled(call_id) -> bool"},
    {"js_eval", stow_js_eval, METH_VARARGS, "js_eval(script) -> console output"},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef stow_module = {
    PyModuleDef_HEAD_INIT, "_stow", "Callbacks into the Stow app.", -1, stow_methods,
};

static PyObject *PyInit__stow(void) {
    return PyModule_Create(&stow_module);
}

// MARK: - Helpers

static char *stow_strdup_status(const char *prefix, PyStatus status) {
    const char *message = status.err_msg ? status.err_msg : "unknown error";
    size_t size = strlen(prefix) + strlen(message) + 3;
    char *result = malloc(size);
    snprintf(result, size, "%s: %s", prefix, message);
    return result;
}

/// The pending Python exception as a malloc'd string (and clears it).
static char *stow_take_exception(const char *prefix) {
    PyObject *exception = PyErr_GetRaisedException();
    const char *text = "unknown error";
    PyObject *string = NULL;
    if (exception) {
        string = PyObject_Str(exception);
        if (string) text = PyUnicode_AsUTF8(string);
        if (!text) text = "unprintable error";
    }
    size_t size = strlen(prefix) + strlen(text) + 3;
    char *result = malloc(size);
    snprintf(result, size, "%s: %s", prefix, text);
    Py_XDECREF(string);
    Py_XDECREF(exception);
    PyErr_Clear();
    return result;
}

static int stow_set_wide(PyConfig *config, wchar_t **field, const char *value) {
    PyStatus status = PyConfig_SetBytesString(config, field, value);
    return PyStatus_Exception(status) ? -1 : 0;
}

// MARK: - Swift -> Python

char *stow_py_start(const StowPyConfig *config) {
    if (Py_IsInitialized()) return strdup("Python is already running");
    stow_on_event = config->onEvent;
    stow_is_cancelled = config->isCancelled;
    stow_evaluate_js = config->evaluateJS;

    if (PyImport_AppendInittab("_stow", PyInit__stow) != 0) return strdup("could not register _stow");

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) return stow_strdup_status("pre-initialize", status);

    PyConfig pyconfig;
    PyConfig_InitIsolatedConfig(&pyconfig);
    // stdout and stderr go to the system log (Console, simctl spawn log stream).
    pyconfig.use_system_logger = 1;
    pyconfig.buffered_stdio = 0;
    // The app owns signals; Python must not install a SIGINT handler.
    pyconfig.install_signal_handlers = 0;
    // Bytecode can't go next to the sources (the bundle is signed), so it goes to Caches.
    pyconfig.write_bytecode = 1;
    if (stow_set_wide(&pyconfig, &pyconfig.home, config->home) != 0 ||
        stow_set_wide(&pyconfig, &pyconfig.pycache_prefix, config->pycachePrefix) != 0) {
        PyConfig_Clear(&pyconfig);
        return strdup("could not set Python's paths");
    }
    status = Py_InitializeFromConfig(&pyconfig);
    PyConfig_Clear(&pyconfig);
    if (PyStatus_Exception(status)) return stow_strdup_status("initialize", status);

    // From here on the GIL is held by this thread.
    char *error = NULL;
    PyObject *site = PyImport_ImportModule("site");
    PyObject *added = site ? PyObject_CallMethod(site, "addsitedir", "s", config->sitePackages) : NULL;
    if (!added) {
        error = stow_take_exception("site-packages");
        goto done;
    }
    Py_DECREF(added);

    PyObject *sys_path = PySys_GetObject("path");  // borrowed
    PyObject *app_path = PyUnicode_FromString(config->appPath);
    if (!sys_path || !app_path || PyList_Insert(sys_path, 0, app_path) != 0) {
        Py_XDECREF(app_path);
        error = stow_take_exception("sys.path");
        goto done;
    }
    Py_DECREF(app_path);

    PyObject *module = PyImport_ImportModule("stow_ytdlp");
    if (!module) {
        error = stow_take_exception("import stow_ytdlp");
        goto done;
    }
    PyObject *started = PyObject_CallMethod(module, "start", "s", config->cacheDir);
    if (!started) {
        Py_DECREF(module);
        error = stow_take_exception("stow_ytdlp.start");
        goto done;
    }
    Py_DECREF(started);
    stow_submit_function = PyObject_GetAttrString(module, "submit");
    Py_DECREF(module);
    if (!stow_submit_function) error = stow_take_exception("stow_ytdlp.submit");

done:
    Py_XDECREF(site);
    // Let Python's own threads run; submit takes the GIL back for a moment each time.
    PyEval_SaveThread();
    return error;
}

char *stow_py_submit(int64_t callID, const char *requestJSON) {
    if (!stow_submit_function) return strdup("Python is not running");
    PyGILState_STATE gil = PyGILState_Ensure();
    char *error = NULL;
    PyObject *result = PyObject_CallFunction(stow_submit_function, "Ls", (long long)callID, requestJSON);
    if (result) {
        Py_DECREF(result);
    } else {
        error = stow_take_exception("submit");
    }
    PyGILState_Release(gil);
    return error;
}

void stow_py_free(void *pointer) {
    free(pointer);
}
