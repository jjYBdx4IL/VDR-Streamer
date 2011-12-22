var ws;
function send (obj) {
    ws.send(JSON.stringify(obj,null,2));
}
function playsec_click_handler () {
    $('+ div',this).toggle('fast');
    return false;
}
function playrec_click_handler () {
    if($('#playerdiv',this).length) return false;
    $('#playerdiv').remove();
    $(this).append($('<div>').attr('id','playerdiv').append('loading ... please wait ...'));
    send({
        cmd: 'play',
        recording: $('div.recname',this).html()
    });
    return false;
}
function showrecs_click_handler () {
    send({cmd: "load"});
    return false;
}
function openplayer_click_handler () {
    //ws.send("load");
    return false;
}
function handle_load_reply (msg) {
    $('.dynsec').html('');
    var dt = new Date(msg.reply.recs_last_updated*1000);
    $('#recs').append($('<pre>').append('Last update: '+dt.toLocaleString()));
    var title = '';
    var container = null;
    var r1 = /^(.*)\/([^\/]+)\.rec$/;
    var r2 = /^([0-9]+-[0-9]+-[0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$/;
    for (var idx in msg.reply.recs) {
        var rec = msg.reply.recs[idx];
        var e = r1.exec(rec);
        if(e == null) next;
        var t = e[1];
        var n = e[2];
        
        // new section required?
        if(t != title) {
            title = t;
            container = $('<div>').addClass('recsec').hide();
            $('#recs').append(
                $('<div>').append(
                    $('<div>').addClass('playsec').append(t)
                ).append(container)
            );
        }
        var e2 = r2.exec(n);
        if(e2!=null) {
            n = e2[1] + '&nbsp;&nbsp;' + e2[2] + ':' + e2[3] + '&nbsp;&nbsp;(priority ' + e2[4] + ')';
        }
        container.append(
            $('<div>').addClass('playrec').append(n)
                .append($('<div>').addClass('recname').append(e[0]).hide())
        );
    }
    $('div.playrec').click(playrec_click_handler);
    $('div.playsec').click(playsec_click_handler);
}
function handle_playstatus_start (msg) {
    //$('.dynsec').html('');
    $('#playerdiv').html('');
    $('#playerdiv').append($('<pre>').addClass('playlog'));
    
    //$('#playerdiv').append('<span id="playstatus_title">').append('<br>');
    //$('#playerdiv').append('<span id="playstatus_position">').append('<br>');
    
    //$('#playstatus_title').html(msg.reply.title);
}
function handle_playstatus_update (msg) {
    //$('#playstatus_position').html(msg.reply.position);
    $('#playerdiv pre.playlog').append(msg.reply.position);
    $('#playerdiv pre.playlog').scrollTop($('#playerdiv pre.playlog')[0].scrollHeight);
}
function onLoad () {
    if ("MozWebSocket" in window) {
        ws = new MozWebSocket(ws_url);
    }
    else if ("WebSocket" in window) {
        ws = new WebSocket(ws_url);
    }
    if(typeof(ws) !== 'undefined') {
        function wsmessage(event) {
            var msg = null;
            eval("msg="+event.data+";");
            if(msg.cmd == 'ping') {
                console.debug('received ping reply');
            }
            if(msg.cmd == 'load') {
                handle_load_reply(msg);
            }
            if(msg.cmd == 'playstatus_start') {
                handle_playstatus_start(msg);
            }
            if(msg.cmd == 'playstatus_update') {
                handle_playstatus_update(msg);
            }
        }
        function wsopen(event) {
            send({cmd:"load"});
            // keep connection alive!
            window.setInterval(function(){send({cmd:"ping"});}, 1000*10);
        }
        ws.onmessage = wsmessage;
        ws.onopen = wsopen;
    }
    else {
        alert("Sorry, your browser does not support WebSockets.");
    }
    
    $('.showrecs').click(showrecs_click_handler);
    //$('.showctrl').click(showctrl_click_handler);
    $('.openplayer').click(openplayer_click_handler);
}
$(document).ready(onLoad);

