"""Apply OpenConnect Sandbox privacy and credential integration."""

import os


if os.environ.get("OPENCONNECT_SANDBOX_EPHEMERAL_SSO") == "1":
    import openconnect_sso.browser.webengine_process as _webengine

    _original_profile = _webengine.QWebEngineProfile

    def _ephemeral_profile(*_args, **_kwargs):
        # Qt's no-name constructor creates an off-the-record profile: cookies,
        # cache, and browser state stay in memory and vanish with the process.
        return _original_profile()

    _ephemeral_profile.openconnect_sandbox_ephemeral = True
    _webengine.QWebEngineProfile = _ephemeral_profile


if os.environ.get("OPENCONNECT_SANDBOX_MANAGED_CREDENTIALS") == "1":
    import openconnect_sso.config as _config

    def _get_password(credentials):
        return getattr(credentials, "_openconnect_sandbox_password", "")

    def _set_password(credentials, value):
        credentials._openconnect_sandbox_password = value or ""

    def _get_totp(credentials):
        return getattr(credentials, "_openconnect_sandbox_totp", "")

    def _set_totp(credentials, value):
        # An empty line is intentional: Duo Push is selected in the browser,
        # and no reusable TOTP seed is ever accepted or stored by this app.
        credentials._openconnect_sandbox_totp = value or ""

    _config.Credentials.password = property(_get_password, _set_password)
    _config.Credentials.totp = property(_get_totp, _set_totp)
    _config.Credentials.openconnect_sandbox_managed = True
