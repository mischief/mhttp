#!/bin/sh
# Makes the test certificates: a CA, a server certificate for localhost
# and 127.0.0.1, a client certificate, and a second server certificate
# for SNI. They are for tests only. The keys are public.
set -e
cd "$(dirname "$0")"
EC="-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes"
DAYS=36500

openssl req -x509 $EC -keyout ca.key -out ca.pem -days $DAYS -subj /CN=mhttp-test-ca
for c in "server /CN=localhost subjectAltName=DNS:localhost,IP:127.0.0.1" \
	"client /CN=alice extendedKeyUsage=clientAuth" \
	"other /CN=other.test subjectAltName=DNS:other.test"; do
	set -- $c
	openssl req $EC -keyout $1.key -out $1.csr -subj $2
	echo "$3" > $1.ext
	openssl x509 -req -in $1.csr -CA ca.pem -CAkey ca.key -set_serial 0x$(openssl rand -hex 8) \
		-days $DAYS -out $1.pem -extfile $1.ext
	rm $1.csr $1.ext
done
