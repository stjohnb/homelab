# Servarr Stack Setup Guide

This guide walks through connecting Overseerr, Sonarr, Radarr, Transmission, and Plex.

## Service URLs

- **Sonarr**: https://sonarr.home.bstjohn.net
- **Radarr**: https://radarr.home.bstjohn.net
- **Prowlarr**: https://prowlarr.home.bstjohn.net (optional - centralized indexer management)
- **Overseerr**: https://overseerr.home.bstjohn.net
- **Transmission**: https://transmission.home.bstjohn.net
- **Plex**: https://plex.home.bstjohn.net

## Architecture Overview

```
User Request (Overseerr)
    ↓
Sonarr/Radarr (search & monitor)
    ↓ (queries indexers)
Prowlarr (optional - manages indexers)
    ↓
Transmission (download via VPN)
    ↓
Media Library (NFS: /mnt/SSD-POOL/media)
    ↓
Plex (stream to users)
```

## Step 1: Configure Sonarr

### 1.1 Initial Setup
1. Navigate to https://sonarr.home.bstjohn.net
2. Complete the initial setup wizard if prompted
3. Set authentication (Settings → General → Authentication: Forms/Basic)

### 1.2 Add Root Folder
1. Go to **Settings → Media Management**
2. Click **Add Root Folder**
3. Enter path: `/tv`
4. Click the checkmark to save

### 1.3 Add Download Client (Transmission)
1. Go to **Settings → Download Clients**
2. Click the **+** button
3. Select **Transmission**
4. Configure:
   - **Name**: Transmission
   - **Host**: `transmission.default.svc.cluster.local`
   - **Port**: `9091`
   - **URL Path**: `/transmission/` (include trailing slash)
   - **Username**: (check Transmission deployment for env vars)
   - **Password**: (check Transmission deployment for env vars)
   - **Category**: `sonarr` (optional, for organization)
   - **Directory**: leave empty (Transmission will use its download dir)
5. Click **Test** then **Save**

### 1.4 Add Indexers

**Option A: Using Prowlarr (Recommended)**

Prowlarr centralizes indexer management. The integration works by adding Sonarr TO Prowlarr (not the other way around).

1. **Deploy Prowlarr first** (if not already running)
2. In **Prowlarr**:
   - Go to **Settings → Apps**
   - Click the **+** button
   - Select **Sonarr**
   - Configure:
     - **Sync Level**: Full Sync
     - **Prowlarr Server**: `http://prowlarr.default.svc.cluster.local:9696`
     - **Sonarr Server**: `http://sonarr.default.svc.cluster.local:8989`
     - **API Key**: Get from Sonarr (Settings → General → Security → API Key)
   - Click **Test** then **Save**
3. Add indexers in Prowlarr (Settings → Indexers)
4. Prowlarr will automatically push all indexers to Sonarr
5. Verify in Sonarr: Settings → Indexers (you should see indexers with "(Prowlarr)" prefix)

**Option B: Manual Indexers (Quick Start)**

If Prowlarr isn't set up yet:
1. Go to **Settings → Indexers** in Sonarr
2. Click the **+** button
3. Select an indexer type (e.g., "Torznab" for most torrent sites)
4. Configure with indexer's URL and API key
5. Click **Test** then **Save**

## Step 2: Configure Radarr

### 2.1 Initial Setup
1. Navigate to https://radarr.home.bstjohn.net
2. Complete the initial setup wizard
3. Set authentication (Settings → General → Authentication: Forms/Basic)

### 2.2 Add Root Folder
1. Go to **Settings → Media Management**
2. Click **Add Root Folder**
3. Enter path: `/movies`
4. Click the checkmark to save

### 2.3 Add Download Client (Transmission)
1. Go to **Settings → Download Clients**
2. Click the **+** button
3. Select **Transmission**
4. Configure:
   - **Name**: Transmission
   - **Host**: `transmission.default.svc.cluster.local`
   - **Port**: `9091`
   - **URL Path**: `/transmission/` (include trailing slash)
   - **Username**: (check Transmission deployment)
   - **Password**: (check Transmission deployment)
   - **Category**: `radarr` (optional)
   - **Directory**: leave empty
5. Click **Test** then **Save**

### 2.4 Add Indexers

**Option A: Using Prowlarr (Recommended)**

If you already set up Prowlarr for Sonarr:
1. In **Prowlarr**:
   - Go to **Settings → Apps**
   - Click the **+** button
   - Select **Radarr**
   - Configure:
     - **Sync Level**: Full Sync
     - **Prowlarr Server**: `http://prowlarr.default.svc.cluster.local:9696`
     - **Radarr Server**: `http://radarr.default.svc.cluster.local:7878`
     - **API Key**: Get from Radarr (Settings → General → Security → API Key)
   - Click **Test** then **Save**
2. Prowlarr will automatically push all indexers to Radarr
3. Verify in Radarr: Settings → Indexers (you should see indexers with "(Prowlarr)" prefix)

**Option B: Manual Indexers**

If Prowlarr isn't set up:
1. Go to **Settings → Indexers** in Radarr
2. Click the **+** button
3. Select an indexer type (e.g., "Torznab")
4. Configure with indexer's URL and API key
5. Click **Test** then **Save**

## Step 3: Configure Plex

### 3.1 Initial Setup
1. Navigate to https://plex.home.bstjohn.net
2. Sign in with your Plex account
3. Complete the server setup wizard

### 3.2 Add Libraries
1. Click **Settings** (wrench icon)
2. Go to **Manage → Libraries**
3. Click **Add Library**

**For TV Shows:**
- Type: **TV Shows**
- Name: **TV Shows** (or your preference)
- Folders: Click **Browse for Media Folder**
  - Navigate to `/tv` (this is the NFS mount in the Plex container)
  - Click **Add**
- Advanced: Enable **Scan my library automatically**
- Click **Add Library**

**For Movies:**
- Type: **Movies**
- Name: **Movies**
- Folders: Click **Browse for Media Folder**
  - Navigate to `/movies` (this is the NFS mount in the Plex container)
  - Click **Add**
- Advanced: Enable **Scan my library automatically**
- Click **Add Library**

### 3.3 Get Plex API Token
You'll need this for Overseerr.

1. Open any Plex media item in your browser
2. Click the three dots (...) → **Get Info** → **View XML**
3. Look at the URL: `...?X-Plex-Token=xxxxxxxxxxxxx`
4. Copy the token after `X-Plex-Token=`

## Step 4: Configure Overseerr

### 4.1 Initial Setup & Plex Connection
1. Navigate to https://overseerr.home.bstjohn.net
2. Click **Sign in with Plex**
3. Authorize Overseerr to access your Plex account
4. Configure Plex server:
   - **Server**: Select your Plex server from the dropdown
   - **Libraries**: Select the TV Shows and Movies libraries you created
   - Click **Continue**

### 4.2 Add Sonarr
1. Go to **Settings → Services**
2. Click **Sonarr** tab
3. Click **Add Sonarr Server**
4. Configure:
   - **Default Server**: Yes (toggle on)
   - **4K Server**: No
   - **Server Name**: Sonarr
   - **Hostname or IP Address**: `sonarr.default.svc.cluster.local`
   - **Port**: `8989`
   - **Use SSL**: No (internal cluster communication)
   - **API Key**:
     - Get from Sonarr: Settings → General → Security → API Key
     - Copy and paste here
   - **URL Base**: leave empty
   - **Quality Profile**: Select default (or create custom in Sonarr first)
   - **Root Folder**: Select `/tv`
   - **Language Profile**: Select default
   - **Tags**: leave empty
   - **Enable Scan**: Yes
   - **Enable Automatic Search**: Yes
5. Click **Test** then **Save Changes**

### 4.3 Add Radarr
1. Still in **Settings → Services**
2. Click **Radarr** tab
3. Click **Add Radarr Server**
4. Configure:
   - **Default Server**: Yes
   - **4K Server**: No
   - **Server Name**: Radarr
   - **Hostname or IP Address**: `radarr.default.svc.cluster.local`
   - **Port**: `7878`
   - **Use SSL**: No
   - **API Key**:
     - Get from Radarr: Settings → General → Security → API Key
     - Copy and paste here
   - **URL Base**: leave empty
   - **Quality Profile**: Select default
   - **Root Folder**: Select `/movies`
   - **Minimum Availability**: Released
   - **Tags**: leave empty
   - **Enable Scan**: Yes
   - **Enable Automatic Search**: Yes
5. Click **Test** then **Save Changes**

## Step 5: Verify Integration

### 5.1 Test Sonarr/Radarr → Transmission
1. In Sonarr or Radarr, go to **System → Tasks**
2. Find the task that tests download clients
3. Manually trigger it to verify connection

### 5.2 Test Overseerr → Sonarr/Radarr
1. In Overseerr, search for a TV show or movie
2. Click **Request**
3. Verify the request appears in Sonarr/Radarr under **Activity**

### 5.3 Test Full Workflow
1. Request a TV show episode or movie in Overseerr
2. Check Sonarr/Radarr to see if it's searching
3. Once found, it should send to Transmission
4. Check Transmission to see the active download
5. When complete, Sonarr/Radarr should import to `/tv` or `/movies`
6. Plex should automatically detect and add to library

## Troubleshooting

### Transmission Authentication
If you need the Transmission credentials:
```bash
kubectl get deployment transmission -o yaml | grep -A5 "env:"
```

Look for `TRANSMISSION_WEB_USER` and `TRANSMISSION_WEB_PASSWORD` environment variables.

### Sonarr/Radarr Can't Connect to Transmission
- Verify Transmission is running: `kubectl get pods | grep transmission`
- Check DNS resolution: `kubectl exec -it <sonarr-pod> -- ping transmission.default.svc.cluster.local`
- Verify port and URL path are correct

### Downloads Not Importing
- Check that Sonarr/Radarr and Transmission mount the same `/downloads` directory
- Verify permissions on NFS mounts
- Check Sonarr/Radarr logs under **System → Logs**

### Plex Not Scanning New Content
- Verify Plex has access to `/tv` and `/movies` directories
- Check that "Scan my library automatically" is enabled
- Manually trigger scan: Library → ... (three dots) → Scan Library Files

## File Paths Reference

| Service | Config Mount | TV Mount | Movies Mount | Downloads Mount |
|---------|-------------|----------|--------------|-----------------|
| Sonarr | `/config` | `/tv` | - | `/downloads` |
| Radarr | `/config` | - | `/movies` | `/downloads` |
| Transmission | `/config` | - | - | `/downloads` |
| Plex | `/config` | `/tv` | `/movies` | - |
| Overseerr | `/config` | - | - | - |

Storage backing for those mounts:

- `/config` — node-local `local-path` PVC per service (`sonarr-local-config-pvc`,
  `radarr-local-config-pvc`, `transmission-local-config-pvc`, …). **Never** on NFS.
- `/tv`, `/movies` — NFS `192.168.0.128:/mnt/SSD-POOL/media`, subPaths `TV` and `Movies`
- `/downloads` — NFS `192.168.0.128:/mnt/SSD-POOL/downloads` (`transmission-downloads-pvc`)

## Next Steps

Once the basic integration is working:
1. **Deploy Prowlarr** (if not already done) and connect Sonarr/Radarr as apps
2. **Add indexers** in Prowlarr (they'll sync to both Sonarr and Radarr automatically)
3. Configure quality profiles in Sonarr/Radarr
4. Set up notification webhooks (Discord, Slack, etc.)
5. Configure user permissions in Overseerr
6. Set up automatic library updates in Plex
