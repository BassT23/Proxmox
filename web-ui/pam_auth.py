"""Small PAM authentication adapter using the host's existing PAM stack."""

import ctypes
import ctypes.util


PAM_SUCCESS = 0
PAM_PROMPT_ECHO_ON = 2
PAM_PROMPT_ECHO_OFF = 1


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_char_p), ("resp_retcode", ctypes.c_int)]


CONV_FUNC = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_int,
    ctypes.POINTER(ctypes.POINTER(PamMessage)),
    ctypes.POINTER(ctypes.POINTER(PamResponse)),
    ctypes.c_void_p,
)


class PamConv(ctypes.Structure):
    _fields_ = [("conversation", CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


def authenticate(username, password, service="login"):
    """Authenticate once through an existing PAM service.

    The password is passed only through the in-memory conversation callback.
    No PAM configuration or account/session state is changed here.
    """
    library_name = ctypes.util.find_library("pam") or "libpam.so.0"
    pam = ctypes.CDLL(library_name)
    libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
    pam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
                              ctypes.POINTER(PamConv), ctypes.POINTER(ctypes.c_void_p)]
    pam.pam_start.restype = ctypes.c_int
    pam.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_authenticate.restype = ctypes.c_int
    pam.pam_acct_mgmt.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_acct_mgmt.restype = ctypes.c_int
    pam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
    pam.pam_end.restype = ctypes.c_int
    libc.strdup.argtypes = [ctypes.c_char_p]
    libc.strdup.restype = ctypes.c_void_p

    username_bytes = username.encode("utf-8")
    password_bytes = password.encode("utf-8")
    allocated = []
    libc.calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
    libc.calloc.restype = ctypes.c_void_p

    @CONV_FUNC
    def conversation(num_msg, message_ptr, response_ptr, _appdata):
        if num_msg < 0 or not response_ptr:
            return 19  # PAM_CONV_ERR
        response_memory = libc.calloc(num_msg, ctypes.sizeof(PamResponse))
        if not response_memory:
            return 5  # PAM_BUF_ERR
        responses = ctypes.cast(response_memory, ctypes.POINTER(PamResponse))
        for index in range(num_msg):
            message = message_ptr[index].contents
            if message.msg_style in (PAM_PROMPT_ECHO_ON, PAM_PROMPT_ECHO_OFF):
                value = username_bytes if message.msg_style == PAM_PROMPT_ECHO_ON else password_bytes
                duplicate = libc.strdup(value)
                if not duplicate:
                    return 5  # PAM_BUF_ERR
                allocated.append(duplicate)
                responses[index].resp = ctypes.cast(duplicate, ctypes.c_char_p)
                responses[index].resp_retcode = 0
            else:
                responses[index].resp = None
                responses[index].resp_retcode = 0
        response_ptr[0] = responses
        return PAM_SUCCESS

    handle = ctypes.c_void_p()
    conversation_struct = PamConv(conversation, None)
    result = pam.pam_start(service.encode("ascii"), username_bytes,
                           ctypes.byref(conversation_struct), ctypes.byref(handle))
    if result != PAM_SUCCESS:
        return False
    try:
        result = pam.pam_authenticate(handle, 0)
        if result == PAM_SUCCESS:
            result = pam.pam_acct_mgmt(handle, 0)
        return result == PAM_SUCCESS
    finally:
        pam.pam_end(handle, result)
