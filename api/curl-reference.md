# API cURL reference

## fetchUserDetail

```bash
curl -sS -X GET \
  'http://ums.prod-we.com/ums/v2/user/fetchDetail?userCodes=<USER_CODE>' \
  -H 'X-APP-VERSION: 24.1.0' \
  -H 'X-APP-NAME: 24.1.0' \
  -H 'locale: en' \
  -H 'X-APP-PLATFORM: android' \
  -H 'Cache-Control: no-cache' \
  -H 'service: OperatorApp'
```

## login

```bash
curl -sS -X POST \
  'https://wheelseye.com/shield/admin/v3/login' \
  -H 'Content-Type: application/json' \
  -H 'X-APP-VERSION: 24.1.0' \
  -H 'X-APP-NAME: 24.1.0' \
  -H 'locale: en' \
  -H 'X-APP-PLATFORM: android' \
  -H 'Cache-Control: no-cache' \
  -H 'service: OperatorApp' \
  -d '{"password":"<PASSWORD>","type":"OPERATOR","userName":"<MOBILE_NUMBER>","userConsent":true}'
```

## getAllFilterCount

```bash
curl -sS -X GET \
  'https://wheelseye.com/argus/app/vehicles/getAllFilterCount' \
  -H 'token: <TOKEN>' \
  -H 'user-code: <USER_CODE>' \
  -H 'DEVICE_NAME: <DEVICE_NAME>' \
  -H 'DEVICE-ID: <DEVICE_ID>' \
  -H 'X-DEVICE-ID: <DEVICE_ID>' \
  -H 'ANDROID_VERSION: <ANDROID_VERSION>' \
  -H 'X-APP-VERSION: 24.1.0' \
  -H 'X-APP-NAME: 24.1.0' \
  -H 'locale: en' \
  -H 'X-APP-PLATFORM: android' \
  -H 'Cache-Control: no-cache' \
  -H 'service: OperatorApp'
```

## fastagHomeComponent

```bash
curl -sS -X POST \
  'https://wheelseye.com/rest/cyborg/app/fastag/home/component' \
  -H 'Content-Type: application/json' \
  -H 'token: <TOKEN>' \
  -H 'user-code: <USER_CODE>' \
  -H 'DEVICE_NAME: <DEVICE_NAME>' \
  -H 'DEVICE-ID: <DEVICE_ID>' \
  -H 'X-DEVICE-ID: <DEVICE_ID>' \
  -H 'ANDROID_VERSION: <ANDROID_VERSION>' \
  -H 'X-APP-VERSION: 24.1.0' \
  -H 'X-APP-NAME: 24.1.0' \
  -H 'locale: en' \
  -H 'X-APP-PLATFORM: android' \
  -H 'Cache-Control: no-cache' \
  -H 'service: OperatorApp' \
  -d '{
    "component": "VEHICLE_LISTING",
    "userType": "HAS_FASTAG",
    "params": {
      "spId": 13,
      "pageNo": 1,
      "pageSize": 5,
      "searchText": "",
      "service": null
    }
  }'
```
