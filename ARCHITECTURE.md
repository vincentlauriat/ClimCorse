# Architecture — ClimCorse

## Vue d'ensemble

```
┌─────────────────────────────────────────────┐
│  Vues                                       │
│  ContentView · DeviceDetailView             │
│  MenuBarView · SignInView · SettingsView    │
└───────────────────┬─────────────────────────┘
                    │ @EnvironmentObject
┌───────────────────▼─────────────────────────┐
│  ClimateViewModel                           │
│  sondage · écritures optimistes · anti-rebond│
└───────────────────┬─────────────────────────┘
                    │
┌───────────────────▼─────────────────────────┐
│  ComfortCloudClient                         │
│  unités · état (direct→cache) · commandes   │
└──────┬──────────────────────┬───────────────┘
       │                      │
┌──────▼───────────┐  ┌───────▼────────────────┐
│ ComfortCloudAuth │  │ RequestSigner          │
│ OAuth2 + PKCE    │  │ x-cfc-api-key, en-têtes│
└──────┬───────────┘  └────────────────────────┘
       │
┌──────▼───────────┐
│ Keychain         │
│ jetons           │
└──────────────────┘
```

## Source de vérité du protocole

Panasonic ne publie aucune API. Chaque constante, en-tête et point d'entrée
provient du comportement de l'application Android officielle, tel qu'implémenté
par le client open source maintenu `aio-panasonic-comfort-cloud` (celui qui fait
tourner l'intégration Home Assistant `sockless-coding/panasonic_cc`). Ces
éléments ont été lus dans le code source, pas restitués de mémoire — le
protocole évolue, et un souvenir périmé produit des 401 silencieux.

## Authentification

Flux OAuth 2.0 « authorization code » avec PKCE contre le tenant Auth0 de
Panasonic, sur `authglb.digital.panasonic.com`.

`ASWebAuthenticationSession` présente la page de connexion de Panasonic.
Panasonic gère lui-même le mot de passe et la double authentification ;
l'application ne reçoit que le code d'autorisation. Les clients Python, eux,
envoient les identifiants en POST puis analysent le HTML d'Auth0 pour en
extraire les champs cachés — ce qui casse à chaque refonte de leur page et
suppose de détenir le mot de passe de l'utilisateur.

L'URI de redirection est le scheme personnalisé de l'application Android :
`panasonic-iot-cfc://authglb.digital.panasonic.com/android/com.panasonic.ACCsmart/callback`.
L'application déclare ce scheme dans `CFBundleURLTypes`. **S'il s'avère que le
callback ne parvient pas à `ASWebAuthenticationSession`, le repli est une feuille
`WKWebView` interceptant la redirection dans `decidePolicyFor` — ce qui donne
en prime la maîtrise du User-Agent.**

La connexion se fait en deux temps : après l'échange du jeton, un POST sur
`accsmart.panasonic.com/auth/v2/login` renvoie un `clientId` qui doit
accompagner tous les appels suivants dans l'en-tête `x-client-id`.

### Asymétrie des scopes

`/authorize` demande `openid offline_access comfortcloud.control a2w.control`,
mais l'échange du jeton n'envoie que `openid`. Le rafraîchissement réutilise le
scope *stocké*. C'est le comportement du client officiel ; s'en écarter fait
refuser la requête.

## Signature des requêtes

Chaque appel à l'API de contrôle porte un `x-cfc-api-key` :

```
SHA256("Comfort Cloud" + sel + timestamp_ms + "Bearer " + jeton)
→ hex[0..<9] + "cfc" + hex[9...]
```

La subtilité : l'horodatage est formaté en heure **locale** (et envoyé tel quel
dans `x-app-timestamp`), puis relu **comme s'il était en UTC** pour en déduire
les millisecondes. Ce décalage n'est pas un défaut à corriger — c'est ce
qu'attend le serveur. Le normaliser casse toutes les requêtes hors UTC.

## Lecture de l'état

`GET /deviceStatus/{guid}` interroge l'unité en direct. Quand elle est
injoignable, l'appel échoue et le client bascule sur
`GET /deviceStatus/now/{guid}` — le cache serveur — pendant dix cycles de
sondage avant de retenter le direct. Les modules Wi-Fi mettent du temps à se
rétablir, et réessayer le direct à chaque cycle ne fait qu'accumuler les délais
d'attente.

Les GUID d'appareil contiennent des `/` que le serveur attend remplacés par `f`
avant encodage. L'oublier casse silencieusement la lecture d'état sur certaines
unités.

Une température de `126` est une valeur sentinelle signalant une sonde absente
ou hors ligne, pas une mesure ; elle est masquée.

## Écriture

`POST /deviceStatus/control` avec `{"deviceGuid": …, "parameters": {…}}`.

L'oscillation est le cas délicat : « auto » n'est pas une valeur de
`airSwingLR`/`airSwingUD` mais un champ distinct, `fanAutoMode`, qui se comporte
comme un masque de bits couvrant les **deux** axes. Régler un axe suppose donc
de connaître l'état de l'autre — le client le prend dans le dernier état connu
de l'appareil plutôt que d'émettre une lecture supplémentaire.

## Comportement de l'interface

Les allers-retours vers le cloud prennent plusieurs secondes. Les commandes
s'appliquent immédiatement au modèle local et se réconcilient au sondage
suivant ; une écriture en échec rétablit l'état précédent et remonte l'erreur.
La consigne est temporisée de 700 ms afin qu'un déplacement de curseur envoie
une requête, et non une par demi-degré.
