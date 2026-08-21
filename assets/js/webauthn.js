// WebAuthn passkey ceremonies (BC-US-145).
//
// The LiveView pushes "webauthn-register" / "webauthn-authenticate" with a
// `publicKey` options map whose binary fields are base64url-encoded. This
// hook runs the browser ceremony and pushes back "webauthn-result" (fields
// base64url-encoded again) or "webauthn-error". When the browser lacks
// WebAuthn support it pushes "webauthn-unsupported" on mount.

function base64urlToBuffer(base64url) {
  const base64 = base64url.replace(/-/g, "+").replace(/_/g, "/")
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4)
  const binary = atob(padded)
  const buffer = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) buffer[i] = binary.charCodeAt(i)
  return buffer.buffer
}

function bufferToBase64url(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function webAuthnSupported() {
  return typeof window.PublicKeyCredential !== "undefined" &&
    navigator.credentials &&
    typeof navigator.credentials.create === "function"
}

function decodeCreationOptions(publicKey) {
  const options = {
    ...publicKey,
    challenge: base64urlToBuffer(publicKey.challenge),
    user: {...publicKey.user, id: base64urlToBuffer(publicKey.user.id)},
  }
  options.excludeCredentials = (publicKey.excludeCredentials || []).map(cred => ({
    ...cred,
    id: base64urlToBuffer(cred.id),
  }))
  return options
}

function decodeRequestOptions(publicKey) {
  const options = {...publicKey, challenge: base64urlToBuffer(publicKey.challenge)}
  options.allowCredentials = (publicKey.allowCredentials || []).map(cred => ({
    ...cred,
    id: base64urlToBuffer(cred.id),
  }))
  return options
}

const WebAuthn = {
  mounted() {
    if (!webAuthnSupported()) {
      this.pushEvent("webauthn-unsupported", {})
    }

    this.handleEvent("webauthn-register", ({publicKey}) => {
      if (!this.ensureSupported()) return

      navigator.credentials
        .create({publicKey: decodeCreationOptions(publicKey)})
        .then(credential => {
          const response = credential.response
          const transports =
            typeof response.getTransports === "function" ? response.getTransports() : []

          this.pushEvent("webauthn-result", {
            credentialId: bufferToBase64url(credential.rawId),
            attestationObject: bufferToBase64url(response.attestationObject),
            clientDataJSON: bufferToBase64url(response.clientDataJSON),
            transports: transports,
          })
        })
        .catch(error => this.pushCeremonyError(error))
    })

    this.handleEvent("webauthn-authenticate", ({publicKey}) => {
      if (!this.ensureSupported()) return

      navigator.credentials
        .get({publicKey: decodeRequestOptions(publicKey)})
        .then(credential => {
          const response = credential.response

          this.pushEvent("webauthn-result", {
            credentialId: bufferToBase64url(credential.rawId),
            authenticatorData: bufferToBase64url(response.authenticatorData),
            signature: bufferToBase64url(response.signature),
            clientDataJSON: bufferToBase64url(response.clientDataJSON),
            userHandle: response.userHandle ? bufferToBase64url(response.userHandle) : null,
          })
        })
        .catch(error => this.pushCeremonyError(error))
    })
  },

  ensureSupported() {
    if (webAuthnSupported()) return true
    this.pushEvent("webauthn-unsupported", {})
    this.pushEvent("webauthn-error", {
      message: "This browser does not support passkeys (WebAuthn).",
    })
    return false
  },

  pushCeremonyError(error) {
    const message =
      error && error.name === "NotAllowedError"
        ? "The passkey request was cancelled or timed out."
        : (error && error.message) || "The passkey ceremony failed."
    this.pushEvent("webauthn-error", {message})
  },
}

export default WebAuthn
