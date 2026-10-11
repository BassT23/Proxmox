"""Regression coverage for dynamic TFA form validity transitions."""

from pathlib import Path


source = (Path(__file__).parents[1] / "web-ui/server.py").read_text(encoding="utf-8")

login_markup = source.split('<section id="login-screen"', 1)[1].split('</section>', 1)[0]
response_markup = login_markup.split('id="login-tfa-response"', 1)[0]
assert 'required' not in response_markup.rsplit('<input', 1)[-1]

assert "function resetTfaFormState()" in source
assert "response.required=false" in source
assert "response.required=!webauthn" in source
assert "resetTfaFormState();pendingTfa=challenge" in source
assert "const challenge=pendingTfa;resetTfaFormState();setLoginLoading(false)" in source

print("web TFA form-state regression tests: PASS")
