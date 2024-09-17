#!/bin/bash

## Private: Setup the root CA
#
# Usage:
#   setup_root_ca
setup_root_ca() {
  echo "Generating root CA CSR..."
  openssl req -new \
    -config etc/root-ca.conf \
    -out ca/root-ca.csr \
    -keyout ca/root-ca/private/root-ca.key
  echo "Signing root CA CSR..."
  openssl ca -selfsign \
    -config etc/root-ca.conf \
    -in ca/root-ca.csr \
    -out ca/root-ca.crt \
    -extensions root_ca_ext
  # Create DER version of certificate
  openssl x509 \
    -in ca/root-ca.crt \
    -out ca/root-ca.cer \
    -outform der
}

## Private: Setup an intermediate CS
#
# Usage:
#   setup_intermediate_ca caName
setup_intermediate_ca() {
  echo "Generating ${1} intermediate CA CSR..."
  openssl req -new \
    -config "etc/${1}-ca.conf" \
    -out "ca/${1}-ca.csr" \
    -keyout "ca/${1}-ca/private/${1}-ca.key"
  echo "Signing ${1} intermediate CA CSR..."
  openssl ca \
    -config etc/root-ca.conf \
    -in "ca/${1}-ca.csr" \
    -out "ca/${1}-ca.crt" \
    -extensions "${1}_ca_ext"
  # Create DER version of certificate
  openssl x509 \
    -in "ca/${1}-ca.crt" \
    -out "ca/${1}-ca.cer" \
    -outform der
  # Create PEM certificate chain
  cat "ca/${1}-ca.crt" ca/root-ca.crt > "ca/${1}-ca-chain.pem"
}

## Private: Set the organizationName in the config files
#
# Usage:
#   set_organization_name organizationName
set_organization_name() {
  find etc -type f -exec sed -i "s/Simple Inc/${1}/g" {} +
}

## Setup the PKI
#
# Usage:
#   setup organizationName
setup() {
  set_organization_name "${1}"
  setup_root_ca
  setup_intermediate_ca "signing"
  setup_intermediate_ca "mtls"
}

## Private: Sign a TLS server certificate CSR
#
# Usage:
#   sign_server hostname
sign_server() {
  echo "Signing ${1} server CSR..."
  openssl ca \
    -config etc/signing-ca.conf \
    -in "reqs/signing/${FILENAME}.csr" \
    -out "certs/signing/${FILENAME}.crt" \
    -extensions server_ext
  # Create DER version of certificate
  openssl x509 \
    -in "certs/signing/${FILENAME}.crt" \
    -out "certs/signing/${FILENAME}.cer" \
    -outform der
}

## Create a new TLS server certificate
#
# Usage:
#   create_server hostname ip
create_server() {
  FILENAME="${1/./-}"
  echo "Generating ${1} server CSR..."
  DNS="${1}" IP="${2}" \
  openssl req -new \
    -config etc/server.conf \
    -out "reqs/signing/${FILENAME}.csr" \
    -keyout "certs/signing/${FILENAME}.key"
  sign_server "${1}"
}

## Private: Sign a mTLS client certificate CSR
#
# Usage:
#   sign_client commonName
sign_client() {
  FILENAME="${1/./-}"
  echo "Signing ${1} mTLS client CSR..."
  openssl ca \
    -config etc/mtls-ca.conf \
    -in "reqs/mtls/${FILENAME}.csr" \
    -out "certs/mtls/${FILENAME}.crt" \
    -extensions client_ext
  openssl x509 \
    -in "certs/mtls/${FILENAME}.crt" \
    -out "certs/mtls/${FILENAME}.cer" \
    -outform der
}

## Create a new mTLS client certificate
#
# Usage:
#   create_client commonName
create_client() {
  FILENAME="${1/./-}"
  echo "Generating ${1} mTLS client CSR..."
  CN="${1}" \
  openssl req -new \
    -config etc/client.conf \
    -out "reqs/mtls/${FILENAME}.csr" \
    -keyout "certs/mtls/${FILENAME}.key"
  sign_client "${1}"
}

## Create a new CRL in PEM format for the root CA
#
# Usage:
#   create_root_crl
create_root_crl() {
  echo "Generating CRL for ${1} CA..."
  openssl ca -gencrl \
    -config etc/root-ca.conf \
    -out crls/root-ca.crl
}

## Create a new CRL in PEM format for the given intermediate CA
#
# Usage:
#   create_crl intermediateCa
create_crl() {
  if [ $1 = "root" ]; then echo "Use create_root_crl instead." && exit 1; fi
  echo "Generating CRL for ${1} CA..."
  openssl ca -gencrl \
    -config "etc/${1}-ca.conf" \
    -out "crls/${1}-ca.crl"
  # Create CRL PEM chain
  cat crls/root-ca.crl "crls/${1}-ca.crl" > "crls/${1}-ca-chain.crl"
}

## Revoke a certificate signed by the given CA
#
# Usage:
#   revoke caName commonName reason
#   reason is one of: unspecified, keyCompromise, CACompromise, affiliationChanged, superseded, cessationOfOperation, certificateHold,
#   see https://docs.openssl.org/master/man1/openssl-ca/#crl-options
revoke() {
  serial="$(grep "$2" ca/"$1"-ca/db/"$1"-ca.db | awk '{print $3}' | tail -1)"
  echo "Revoking certificate for ${2} from ${1} CA due to ${3}..."
  openssl ca \
    -config "etc/${1}-ca.conf" \
    -revoke "ca/${1}-ca/${serial}.pem" \
    -crl_reason "${3}"
}

## Renew a server certificate
#
# Usage:
#   renew_server commonName
renew_server() {
  FILENAME="${1/./-}"
  revoke "signing" "${1}" "superseded"
  create_crl "signing"
  sign_server "${1}"
}

## Renew a client certificate
#
# Usage:
#   renew_client commonName
renew_client() {
  FILENAME="${1/./-}"
  revoke "mtls" "${1}" "superseded"
  create_crl "mtls"
  sign_client "${1}"
}

## View a certificate
#
# Usage:
#   view_cert commonName
view_cert() {
  FILENAME="${1/./-}"
  openssl x509 \
    -in "certs/${FILENAME}.crt" \
    -noout \
    -text
}

## View a CA certificate
#
# Usage:
#   view_ca_cert caName
view_ca_cert() {
  openssl x509 \
    -in "ca/${1}-ca.crt" \
    -noout \
    -text
}

## View the certificates of a given CA
#
# Usage:
#   view_certs_of_ca caName
view_certs_of_ca() {
  cat "ca/${1}-ca/db/${1}-ca.db"
}

## Build a client p12 bundle
#
# Usage:
#   build_client_p12 commonName
build_client_p12() {
  FILENAME="${1/./-}"
  echo -e "\nGenerating p12 bundle for ${1} ...\n"
  openssl pkcs12 -export -out "p12/${FILENAME}.p12" -inkey "certs/mtls/${FILENAME}.key" -in "certs/mtls/${FILENAME}.crt"
}

## Build a client p12 bundle with special configuration for use with iOS devices
#
# Usage:
#   build_client_p12_ios commonName
build_client_p12_ios() {
  FILENAME="${1/./-}"
  echo -e "\nGenerating p12 bundle for ${1} for iOS ...\n"
  # Adding -legacy -certpbe pbeWithSHA1And40BitRC2-CBC for iOS compatibility, but breaks Chromium compatibility!
  openssl pkcs12 -export -legacy -certpbe pbeWithSHA1And40BitRC2-CBC -out "p12/${FILENAME}.p12" -inkey "certs/mtls/${FILENAME}.key" -in "certs/mtls/${FILENAME}.crt"
}

"${@}"
