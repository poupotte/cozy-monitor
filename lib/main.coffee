# This program is suited only to manage your cozy installation from the inside
# Moreover app management works only for apps make by Cozy Cloud company.
# If you want a friendly application manager you should use the
# appmanager.coffee script.

require "colors"

program = require 'commander'
async = require "async"
fs = require "fs"
exec = require('child_process').exec
spawn = require('child_process').spawn

Client = require("request-json").JsonClient
ControllerClient = require("cozy-clients").ControllerClient
axon = require 'axon'

pkg = require '../package.json'
version = pkg.version

couchUrl = "http://localhost:5984/"
dataSystemUrl = "http://localhost:9101/"
indexerUrl = "http://localhost:9102/"
controllerUrl = "http://localhost:9002/"
homeUrl = "http://localhost:9103/"
proxyUrl = "http://localhost:9104/"
postfixUrl = "http://localhost:25/"

homeClient = new Client homeUrl
statusClient = new Client ''
appsPath = '/usr/local/cozy/apps'


getIds = () ->
    if fs.existsSync '/etc/cozy/gitlab.login'
        try
            ids = fs.readFileSync '/etc/cozy/gitlab.login', 'utf8'
            id = ids.split('\n')[0]
            pwd = ids.split('\n')[1]
            return [id, pwd]
        catch err
            console.log("Are you sure, you are root ?")
            return null
    else
        return null

apps = {
    "contacts":
        "Contact":
            "description": "Creates and edits your contacts."
        "CozyInstance":
          "description": "Read language setting"
        "ContactConfig":
          "description": "Store your settings for contacts"
        "PhoneCommunicationLog":
          "description": "FING/Orange retrieve calls log from your invoice"
        "ContactLog":
          "description": "Log your history with a contact"
        "Mail":
          "description": "Display last emails for a contact"
        "Task":
          "description": "Create call tasks from a contact"
        "TodoList": 
          "description": "Create the \"inbox\" TodoList"
        "Tree": 
          "description": "Find the Inbox TodoList"
    "photos":
        "Photo":
            "description": "Creates and edits your photos"
        "Album": 
          "description": "Creates and edits your album which contains your photos."
        "Contact":
          "description": "Allows you to easily share an album"
        "CozyInstance": 
          "description": "Read language setting"
        "Send mail from user": 
          "description": "Share album with your friends"
        "File": 
          "description": "Navigate in all files to create new album"

}

## Helpers

randomString = (length) ->
    string = ""
    while (string.length < length)
        string = string + Math.random().toString(36).substr(2)
    return string.substr 0, length


getToken = () ->
    if fs.existsSync '/etc/cozy/controller.token'
        try
            token = fs.readFileSync '/etc/cozy/controller.token', 'utf8'
            token = token.split('\n')[0]
            return token
        catch err
            console.log("Are you sure, you are root ?")
            return null
    else
        return null


getAuthCouchdb = (callback) ->
    fs.readFile '/etc/cozy/couchdb.login', 'utf8', (err, data) =>
        if err
            console.log "Cannot read login in /etc/cozy/couchdb.login"
            callback err
        else
            username = data.split('\n')[0]
            password = data.split('\n')[1]
            callback null, username, password


handleError = (err, body, msg) ->
    console.log err if err
    console.log msg
    if body?
        if body.msg?
           console.log body.msg
        else if body.error?.message?
            console.log "An error occured."
            console.log body.error.message
            console.log body.error.result
            console.log body.error.code
            console.log body.error.blame
        else console.log body
    process.exit 1


compactViews = (database, designDoc, callback) ->
    client = new Client couchUrl
    getAuthCouchdb (err, username, password) ->
        if err
            process.exit 1
        else
            client.setBasicAuth username, password
            path = "#{database}/_compact/#{designDoc}"
            client.post path, {}, (err, res, body) =>
                if err
                    handleError err, body, "compaction failed for #{designDoc}"
                else if not body.ok
                    handleError err, body, "compaction failed for #{designDoc}"
                else
                    callback null


compactAllViews = (database, designs, callback) ->
    if designs.length > 0
        design = designs.pop()
        console.log("views compaction for #{design}")
        compactViews database, design, (err) =>
            compactAllViews database, designs, callback
    else
        callback null


waitCompactComplete = (client, found, callback) ->
    setTimeout ->
        client.get '_active_tasks', (err, res, body) =>
            exist = false
            for task in body
                if task.type is "database_compaction"
                    exist = true
            if (not exist) and found
                callback true
            else
                waitCompactComplete(client, exist, callback)
    , 500


waitInstallComplete = (slug, callback) ->
    axon   = require 'axon'
    socket = axon.socket 'sub-emitter'
    socket.connect 9105

    timeoutId = setTimeout ->
        socket.close()

        statusClient.host = homeUrl
        statusClient.get "api/applications/", (err, res, apps) ->
            return unless apps?.rows?

            for app in apps.rows
                console.log slug, app.slug, app.state, app.port
                if app.slug is slug and app.state is 'installed' and app.port
                    statusClient.host = "http://localhost:#{app.port}/"
                    statusClient.get "", (err, res) ->
                        if res?.statusCode in [200, 403]
                            callback null, state: 'installed'
                        else
                            handleError null, null, "Install home failed"
                    return

            handleError null, null, "Install home failed"

    , 240000

    socket.on 'application.update', (id) ->
        clearTimeout timeoutId
        socket.close()

        dSclient = new Client dataSystemUrl
        dSclient.setBasicAuth 'home', token if token = getToken()
        dSclient.get "data/#{id}/", (err, response, body) ->
            if response.statusCode is 401
                dSclient.setBasicAuth 'home', ''
                dSclient.get "data/#{id}/", (err, response, body) ->
                    callback err, body
            else
                callback err, body

prepareCozyDatabase = (username, password, callback) ->
    client.setBasicAuth username, password
    # Remove cozy database
    client.del "cozy", (err, res, body) ->
        # Create new cozy database
        client.put "cozy", {}, (err, res, body) ->
            # Add member in cozy database
            data =
                "admins":
                    "names":[username]
                    "roles":[]
                "readers":
                    "names":[username]
                    "roles":[]
            client.put 'cozy/_security', data, (err, res, body)->
                if err?
                    console.log err
                    process.exit 1
                callback()


token = getToken()
client = new ControllerClient
    token: token

manifest =
   "domain": "localhost"
   "repository":
       "type": "git",
   "scripts":
       "start": "server.coffee"


program
  .version(version)
  .usage('<action> <app>')


## Applications management ##

# Install
program
    .command("install <app>")
    .description("Install application")
    .option('-r, --repo <repo>', 'Use specific repo')
    .option('-b, --branch <branch>', 'Use specific branch')
    .action (app, options) ->
        manifest.name = app
        manifest.password = randomString 12
        manifest.user = app
        console.log "Install started for #{app}..."
        if options.repo?
            manifest.repository.url = options.repo
        else
            [name, password] = getIds()
            if app is 'home'
                manifest.repository.url =
                    "https://#{name}:#{password}@gitlab.cozycloud.cc/cozy/digidisk-files.git"
            else
                manifest.repository.url =
                    "https://#{name}:#{password}@gitlab.cozycloud.cc/cozy/digidisk-#{app}.git" 
        if options.branch?
            manifest.repository.branch = options.branch
        client.clean manifest, (err, res, body) ->
            client.start manifest, (err, res, body)  ->
                if err or body.error?
                    handleError err, body, "Install failed"
                else
                    if app in ['data-system', 'home', 'proxy']
                        console.log "#{app} successfully installed"
                    else
                        manifest.port = body.drone.port
                        manifest.docType = "Application"
                        manifest.state = "installed"
                        manifest.slug = manifest.name
                        manifest.permissions = apps[manifest.name]
                        dSclient = new Client dataSystemUrl
                        dSclient.setBasicAuth 'home', token if token = getToken()
                        dSclient.post 'request/application/all/', {}, (err, res, body) ->
                            if not err?
                                for appli in body
                                    if appli.value.name is app
                                        dSclient.del "data/#{appli.id}/", (err, res, body) =>
                                            console.log 'delete document'
                            dSclient.post 'data/', manifest, (err, res, body) =>
                                console.log "#{app} successfully installed"


# Uninstall
program
    .command("uninstall <app>")
    .description("Remove application")
    .action (app) ->
        console.log "Uninstall started for #{app}..."
        manifest.name = app
        manifest.user = app
        client.clean manifest, (err, res, body) ->
            if err or body.error?
                handleError err, body, "Uninstall failed"
            else
                console.log "#{app} successfully uninstalled"

# Restart
program
    .command("restart <app>")
    .description("Restart application")
    .action (app) ->
        console.log "Stopping #{app}..."
        client.stop app, (err, res, body) ->
            if err or body.error?
                handleError err, body, "Stop failed"
            else
                console.log "#{app} successfully stopped"
                console.log "Starting #{app}..."
                if app in ['home', 'data-system', 'proxy']
                    manifest.name = app
                    manifest.repository.url =
                        "https://github.com/mycozycloud/cozy-#{app}.git"
                    manifest.user = app
                    client.start manifest, (err, res, body) ->
                        if err
                            handleError err, body, "Start failed"
                        else
                            console.log "#{app} sucessfully started"
                else
                    dSclient = new Client dataSystemUrl
                    dSclient.setBasicAuth 'home', token if token = getToken()
                    dSclient.post 'request/application/all/', {}, (err, res, body) ->
                        if not err?
                            for appli in body
                                if appli.value.name is app
                                    manifest.password = appli.value.password
                            manifest.name = app
                            manifest.repository.url =
                                "https://github.com/mycozycloud/cozy-#{app}.git"
                            manifest.user = app
                            client.start manifest, (err, res, body) ->
                                if err
                                    handleError err, body, "Start failed"
                                else
                                    console.log "#{app} sucessfully started"
                        else
                            handleError err, body, "Start failed"

# Chnage branch
program
    .command("branch <app> <branch>")
    .description("Change application branch")
    .action (app, branch) ->
        if app in ['data-system', 'home', 'proxy']
            if app is 'home'
                path = "#{appsPath}/#{app}/#{app}/digidisk-files"
            else  
                path = "#{appsPath}/#{app}/#{app}/digidisk-#{app}" 
        else
            path = "#{appsPath}/#{app}/#{app}/cozy-#{app}"                    
        exec "cd #{path}; git stash && git pull origin #{branch}", (err, res) =>
            if not err?  
                # Restart app
                console.log('restart')
                client.stop app, (err, res, body) ->
                    if err or body.error?
                        handleError err, body, "Stop failed"
                    else
                        console.log "#{app} successfully stopped"
                        console.log "Starting #{app}..."
                        manifest.name = app
                        manifest.repository.url =
                            "https://gitlab.cozycloud.cc/cozy/digidisk-#{app}.git"
                        if app is "home"
                            manifest.repository.url =
                                "https://gitlab.cozycloud.cc/cozy/digidisk-files.git"
                        manifest.user = app
                        client.start manifest, (err, res, body) ->
                                    console.log "#{app} successfully updated"
            else
                handleError err, "", "Update failed"


# Brunch
program
    .command("brunch <app>")
    .description("Build brunch client for given application.")
    .action (app) ->
        console.log "Brunch build #{app}..."
        manifest.name = app
        manifest.repository.url =
            "https ://github.com/mycozycloud/cozy-#{app}.git"
        manifest.user = app
        client.brunch manifest, (err, res, body) ->
            if err or body.error?
                handleError err, body, "Brunch build failed"
            else
                console.log "#{app} client successfully built."

# Update
program
    .command("update <app> <branch> [repo]")
    .description(
        "Update application (git + npm) and restart it. Option repo is usefull " +
            "only if home, proxy or data-system comes from specific repo")
    .action (app, branch, repo) ->
        console.log "Update #{app}..."
        manifest.name = app
        if app is 'home'
            path = "#{appsPath}/#{app}/#{app}/digidisk-files"
        else  
            path = "#{appsPath}/#{app}/#{app}/digidisk-#{app}" 
        manifest.user = app
        # Git pull
        console.log('git pull')
        exec "cd #{path}; git pull origin #{branch}", (err, res) =>
            if not err?
                # Npm install
                console.log('npm install')
                exec "cd #{path}; npm install", (err, res) =>
                    if not err?  
                        # Restart app
                        console.log('restart')
                        client.stop app, (err, res, body) ->
                            if err or body.error?
                                handleError err, body, "Stop failed"
                            else
                                console.log "#{app} successfully stopped"
                                console.log "Starting #{app}..."
                                manifest.name = app
                                manifest.repository.url =
                                    "https://gitlab.cozycloud.cc/cozy/digidisk-#{app}.git"
                                if app is "home"
                                    manifest.repository.url =
                                        "https://gitlab.cozycloud.cc/cozy/digidisk-files.git"
                                if app in ['data-system', 'home', 'proxy']
                                    manifest.user = app
                                    client.start manifest, (err, res, body) ->
                                        if err
                                            handleError err, "", "Update failed"
                                        else
                                            console.log "#{app} successfully updated"
                                else
                                    dSclient = new Client dataSystemUrl
                                    dSclient.setBasicAuth 'home', token if token = getToken()
                                    dSclient.post 'request/application/all/', {}, (err, res, body) ->
                                        if not err?
                                            for appli in body
                                                if appli.value.name is app
                                                    manifest.password = appli.value.password
                                            client.start manifest, (err, res, body) ->
                                                if err
                                                    handleError err, "", "Update failed"
                                                else
                                                    console.log "#{app} successfully updated"
                    else
                        handleError err, "", "Update failed"
            else
                handleError err, "", "Update failed"


# Versions
program
    .command("versions")
    .description("Display applications versions")
    .action () ->
        getVersion = (name) =>
            if name is "controller"
                path = "/usr/local/lib/node_modules/cozy-controller/package.json"
            else if name in ['home', 'proxy', 'data-system']
                path = "#{appsPath}/#{name}/#{name}/digidisk-#{name}/package.json"
            else
                path = "#{appsPath}/#{name}/#{name}/cozy-#{name}/package.json"
            if fs.existsSync path
                data = fs.readFileSync path, 'utf8'
                data = JSON.parse(data)
                console.log "#{name}: #{data.version}"
            else
                console.log("#{name}: unknown")

        getVersionIndexer = (callback) =>
            client = new Client(indexerUrl)
            client.get '', (err, res, body) =>
                if body? and body.split('v')[1]?
                    callback  body.split('v')[1]
                else
                    callback "unknown"

        console.log('Cozy Stack:'.bold)
        getVersion("controller")
        getVersion("data-system")
        getVersion("home")
        getVersion('proxy')
        getVersionIndexer (indexerVersion) =>            
            console.log "indexer: #{indexerVersion}"
            console.log "monitor: #{version}"

## Monitoring ###

program
    .command("dev-route:start <slug> <port>")
    .description("Create a route so we can access it by the proxy. ")
    .action (slug, port) ->
        client = new Client dataSystemUrl
        client.setBasicAuth 'home', token if token = getToken()

        packagePath = process.cwd() + '/package.json'
        try
            packageData = JSON.parse(fs.readFileSync(packagePath, 'utf8'))
        catch e
            console.log "Run this command in the package.json directory"
            console.log e
            return

        perms = {}
        for doctype, perm of packageData['cozy-permissions']
            perms[doctype.toLowerCase()] = perm

        data =
            docType: "Application"
            state: 'installed'
            isStoppable: false
            slug: slug
            name: slug
            password: slug
            permissions: perms
            widget: packageData['cozy-widget']
            port: port
            devRoute: true

        client.post "data/", data, (err, res, body) ->
            if err
                handleError err, body, "Create route failed"
            else
                statusClient.host = proxyUrl
                statusClient.get "routes/reset", (err, res, body) ->
                    if err
                        handleError err, body, "Reset routes failed"
                    else
                        console.log "route created"
                        console.log "start your app with the following ENV"
                        console.log "NAME=#{slug} TOKEN=#{slug} PORT=#{port}"
                        console.log "Use dev-route:stop #{slug} to remove it."


program
    .command("dev-route:stop <slug>")
    .action (slug) ->
        client = new Client dataSystemUrl
        client.setBasicAuth 'home', token if token = getToken()
        appsQuery = 'request/application/all/'

        client.post appsQuery, null, (err, res, apps) ->
            if err or not apps?
                handleError err, apps, "Unable to retrieve apps data."
            else
                for app in apps
                    if (app.key is slug or slug is 'all') and app.value.devRoute
                        delQuery = "data/#{app.id}/"
                        client.del delQuery, (err, res, body) ->
                            if err
                                handleError err, body, "Unable to delete route."
                            else
                                console.log "Route deleted"
                                client.host = proxyUrl
                                client.get 'routes/reset', (err, res, body) ->
                                    if err
                                        handleError err, body, \
                                            "Reset routes failed"
                                    else
                                        console.log "Proxy routes reset"
                        return

            console.log "There is no dev route with this slug"


program
    .command("routes")
    .description("Display routes currently configured inside proxy.")
    .action ->
        console.log "Display proxy routes..."

        statusClient.host = proxyUrl
        statusClient.get "routes", (err, res, routes) ->

            if err
                handleError err, {}, "Cannot display routes."
            else if routes?
                for route of routes
                    console.log "#{route} => #{routes[route].port}"


program
    .command("module-status <module>")
    .description("Give status of given in an easy to parse way.")
    .action (module) ->
        urls =
            controller: controllerUrl
            "data-system": dataSystemUrl
            indexer: indexerUrl
            home: homeUrl
            proxy: proxyUrl
        statusClient.host = urls[module]
        statusClient.get '', (err, res) ->
            if not res? or not res.statusCode in [200, 401, 403]
                console.log "down"
            else
                console.log "up"


program
    .command("status")
    .description("Give current state of cozy platform applications")
    .action ->
        checkApp = (app, host, path="") ->
            (callback) ->
                statusClient.host = host
                statusClient.get path, (err, res) ->
                    if (res? and not res.statusCode in [200,403]) or (err? and err.code is 'ECONNREFUSED')
                        console.log "#{app}: " + "down".red
                    else
                        console.log "#{app}: " + "up".green
                    callback()
                , false

        async.series [
            checkApp "postfix", postfixUrl
            checkApp "couchdb", couchUrl
            checkApp "controller", controllerUrl, "version"
            checkApp "data-system", dataSystemUrl
            checkApp "home", homeUrl
            checkApp "proxy", proxyUrl, "routes"
            checkApp "indexer", indexerUrl
        ], ->
            statusClient.host = homeUrl
            statusClient.get "api/applications/", (err, res, apps) ->
                funcs = []
                if apps? and apps.rows?
                    for app in apps.rows
                        if app.state is 'stopped'
                            console.log "#{app.name}: " + "stopped".grey
                        else
                            url = "http://localhost:#{app.port}/"
                            func = checkApp app.name, url
                            funcs.push func
                    async.series funcs, ->


program
    .command("log <app> <type> [environment]")
    .description("Display application log with cat or tail -f")
    .action (app, type, environment) ->
        env = "production"
        if environment?
            env = environment
        path = "#{appsPath}/#{app}/#{app}/cozy-#{app}/log/#{env}.log"
        if not fs.existsSync(path)
            console.log "Log file doesn't exist"
        else
            if type is "cat"
                console.log fs.readFileSync path, 'utf8'
            else if type is "tail"
                tail = spawn "tail", ["-f", path]

                tail.stdout.setEncoding 'utf8'
                tail.stdout.on 'data', (data) =>
                    console.log data

                tail.on 'close', (code) =>
                    console.log('ps process exited with code ' + code)
            else
                console.log "<type> should be 'cat' or 'tail'"


## Database ##

program
    .command("compact [database]")
    .description("Start couchdb compaction")
    .action (database) ->
        if not database?
            database = "cozy"
        console.log "Start couchdb compaction on #{database} ..."
        client = new Client couchUrl
        getAuthCouchdb (err, username, password) ->
            if err
                process.exit 1
            else
                client.setBasicAuth username, password
                client.post "#{database}/_compact", {}, (err, res, body) ->
                    if err
                        handleError err, body, "Compaction failed."
                    else if not body.ok
                        handleError err, body, "Compaction failed."
                    else
                        waitCompactComplete client, false, (success) =>
                            console.log "#{database} compaction succeeded"
                            process.exit 0


program
    .command("compact-views <view> [database]")
    .description("Start couchdb compaction")
    .action (view, database) ->
        if not database?
            database = "cozy"
        console.log "Start vews compaction on #{database} for #{view} ..."
        compactViews database, view, (err) =>
            if not err
                console.log "#{database} compaction for #{view}" +
                            " succeeded"
                process.exit 0

program
    .command("compact-all-views [database]")
    .description("Start couchdb compaction")
    .action (database) ->
        if not database?
            database = "cozy"
        console.log "Start vews compaction on #{database} ..."
        client = new Client couchUrl
        getAuthCouchdb (err, username, password) ->
            if err
                process.exit 1
            else
                client.setBasicAuth username, password
                path = "#{database}/_all_docs?startkey=\"_design/\"&endkey=" +
                    "\"_design0\"&include_docs=true"
                client.get path, (err, res, body) =>
                    if err
                        handleError err, body, "Views compaction failed. " +
                            "Cannot recover all design documents"
                    else
                        designs = []
                        (body.rows).forEach (design) ->
                            designId = design.id
                            designDoc = designId.substring 8, designId.length
                            designs.push designDoc
                        compactAllViews database, designs, (err) =>
                            if not err
                                console.log "Views are successfully compacted"


program
    .command("cleanup [database]")
    .description("Start couchdb cleanup")
    .action (database) ->
        if not database?
            database = "cozy"
        console.log "Start couchdb cleanup on #{database} ..."
        client = new Client couchUrl
        getAuthCouchdb (err, username, password) ->
            if err
                process.exit 1
            else
                client.setBasicAuth username, password
                client.post "#{database}/_view_cleanup", {}, (err, res, body) ->
                    if err
                        handleError err, body, "Cleanup failed."
                    else if not body.ok
                        handleError err, body, "Cleanup failed."
                    else
                        console.log "#{database} cleanup succeeded"
                        process.exit 0

## Backup ##

program
    .command("backup <target>")
    .description("Start couchdb replication to the target")
    .action (target) ->
        client = new Client couchUrl
        data =
            source: "cozy"
            target: target
        getAuthCouchdb (err, username, password) ->
            if err
                process.exit 1
            else
                client.setBasicAuth username, password
                client.post "_replicate", data, (err, res, body) ->
                    if err
                        handleError err, body, "Backup failed."
                    else if not body.ok
                        handleError err, body, "Backup failed."
                    else
                        console.log "Backup succeeded"
                        process.exit 0


program
    .command("reverse-backup <backup> <username> <password>")
    .description("Start couchdb replication from target to cozy")
    .action (backup, usernameBackup, passwordBackup) ->
        console.log "Reverse backup ..."
        client = new Client couchUrl
        getAuthCouchdb (err, username, password) ->
            if err
                process.exit 1
            else
                prepareCozyDatabase username, password, () ->
                    # Initialize creadentials for backup
                    credentials = "#{usernameBackup}:#{passwordBackup}"
                    basicCredentials = new Buffer(credentials).toString('base64')
                    authBackup = "Basic #{basicCredentials}"
                    # Initialize creadentials for cozy database
                    credentials = "#{username}:#{password}"
                    basicCredentials = new Buffer(credentials).toString('base64')
                    authCozy = "Basic #{basicCredentials}"
                    # Initialize data for replication
                    data =
                        source:
                            url: backup
                            headers:
                                Authorization: authBackup
                        target:
                            url: "#{couchUrl}cozy"
                            headers:
                                Authorization: authCozy
                    # Database replication
                    client.post "_replicate", data, (err, res, body) ->
                        if err
                            handleError err, body, "Backup failed."
                        else if not body.ok
                            handleError err, body, "Backup failed."
                        else
                            console.log "Reverse backup succeeded"
                            process.exit 0

## Others ##

program
    .command("script <app> <script> [argument]")
    .description("Launch script that comes with given application")
    .action (app, script, argument) ->
        argument ?= ''

        console.log "Run script #{script} for #{app}..."
        path = "/usr/local/cozy/apps/#{app}/#{app}/cozy-#{app}/"
        exec "cd #{path}; compound database #{script} #{argument}", \
                     (err, stdout, stderr) ->
            console.log stdout
            if err
                handleError err, stdout, "Script execution failed"
            else
                console.log "Command successfully applied."


program
    .command("reset-proxy")
    .description("Reset proxy routes list of applications given by home.")
    .action ->
        console.log "Reset proxy routes"

        statusClient.host = proxyUrl
        statusClient.get "routes/reset", (err, res, body) ->
            if err
                handleError err, body, "Reset routes failed"
            else
                console.log "Reset proxy succeeded."


program
    .command("*")
    .description("Display error message for an unknown command.")
    .action ->
        console.log 'Unknown command, run "cozy-monitor --help"' + \
                    ' to know the list of available commands.'

program.parse process.argv
