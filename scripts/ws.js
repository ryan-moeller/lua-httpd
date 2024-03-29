{# vim: set et sw=4: #}

const CMD_BE_LIST = "be_list";
const CMD_SNAP_LIST = "snap_list";
const CMD_LATEST = "latest";
const CMD_UPDATE = "update";
const CMD_BE_DESTROY = "be_destroy";
const CMD_SNAP_DELETE = "snap_delete";

const basedir = "/system"

let g_bootenvs = []

function be_find(name) {
    for (const be of g_bootenvs) {
        if (be.name == name) {
            return true;
        }
    }
    return false;
}

function update() {
    const section0 = document.querySelector("#update-available");
    section0.classList.add("is-hidden");
    const section1 = document.querySelector("#updating");
    section1.classList.remove("is-hidden");
    ws_command(CMD_UPDATE);
}

function be_destroy(row, be) {
    const tbody = document.querySelector("#boot-envs-table > table > tbody");
    tbody.deleteRow(row);
    ws_command_data(CMD_BE_DESTROY, {be:be});
}

function snap_delete(row, snap) {
    const tbody = document.querySelector("#snapshots-table > table > tbody");
    tbody.deleteRow(row);
    ws_command_data(CMD_SNAP_DELETE, {snap:snap});
}

const handlers = new Map([
    [CMD_BE_LIST, (bootenvs) => {
        g_bootenvs = bootenvs;
        const tbody = document.createElement("tbody");
        let i = 0;
        for (const be of bootenvs) {
            const row = tbody.insertRow();
            const name = row.insertCell();
            name.innerText = be.name;
            const active = row.insertCell();
            active.innerText = be.active;
            const mountpoint = row.insertCell();
            mountpoint.innerText = be.mountpoint;
            const space = row.insertCell();
            space.innerText = be.space;
            const created = row.insertCell();
            created.innerText = be.created;
            const del = row.insertCell();
            const deleteButton = document.createElement("button");
            deleteButton.classList.add("button", "is-danger");
            deleteButton.innerText = "X";
            const r = i; // Save the current value for the following closure.
            deleteButton.addEventListener("click", () => {
                be_destroy(r, be.name);
            });
            del.appendChild(deleteButton);
            ++i;
        }
        const section = document.querySelector("#boot-envs-table");
        const table = section.querySelector("table");
        table.append(tbody);
        section.classList.remove("is-hidden");
    }],

    [CMD_SNAP_LIST, (snaps) => {
        const tbody = document.createElement("tbody");
        let i = 0;
        for (const snap of snaps) {
            const row = tbody.insertRow();
            const build_date = row.insertCell();
            build_date.innerText = snap.build_date;
            const revision = row.insertCell();
            revision.innerText = snap.revision;
            const path = row.insertCell();
            path.innerText = `${basedir}/${snap.name}`;
            const is_be = row.insertCell();
            is_be.innerText = be_find(snap.name) ? "yes" : "no";
            const del = row.insertCell();
            const deleteButton = document.createElement("button");
            deleteButton.classList.add("button", "is-danger");
            deleteButton.innerText = "X";
            const r = i; // Save the current value for the following closure.
            deleteButton.addEventListener("click", () => {
                snap_delete(r, snap.name);
            });
            del.appendChild(deleteButton);
            ++i;
        }
        const section = document.querySelector("#snapshots-table");
        const table = section.querySelector("table");
        table.append(tbody);
        section.classList.remove("is-hidden");
    }],

    [CMD_LATEST, (name) => {
        if (be_find(name)) {
            const section = document.querySelector("#no-updates");
            section.classList.remove("is-hidden");
        } else {
            const section = document.querySelector("#update-available");
            const label = section.querySelector("label");
            label.innerText = `Update to ${name}?`;
            const button = section.querySelector("button");
            button.value = name;
            section.classList.remove("is-hidden");
        }
    }],

    [CMD_UPDATE, (progress) => {
        if (progress.error) {
            const message = document.querySelector("#updating-error");
            if (progress.rc) {
                const header = message.querySelector("div.message-header");
                const em = header.querySelector("em");
                em.innerText = `${progress.rc}`
            }
            const text = message.querySelector("div.message-body");
            text.innerText = progress.error;
            message.classList.remove("is-hidden");
        } else {
            const section = document.querySelector("#updating");
            const caption = section.querySelector("p");
            caption.innerText = progress.description;
            const bar = section.querySelector("progress");
            bar.value = progress.percent;
        }
    }]
]);

const webSocket = new WebSocket(`ws://${location.host}/ws`);

function ws_command(command) {
    webSocket.send(JSON.stringify({command:command}));
}

function ws_command_data(command, data) {
    webSocket.send(JSON.stringify({command:command,data:data}));
}

webSocket.onopen = (event) => {
    ws_command(CMD_BE_LIST);
    ws_command(CMD_SNAP_LIST);
    ws_command(CMD_LATEST);
}

webSocket.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    const handler = handlers.get(msg.command);
    if (handler) {
        handler(msg.data);
    }
};
