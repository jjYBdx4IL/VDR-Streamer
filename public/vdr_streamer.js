var ws;
function send (obj) {
    ws.send(JSON.stringify(obj,null,2));
}
function playsec_click_handler () {
    $('+ div',this).toggle('fast');
    return false;
}
function playrec_click_handler () {
    if($('+ #playerdiv',this).length) return false;
    $('#playerdiv').remove();
    $(this).after($('<div>').attr('id','playerdiv').append('loading ... please wait ...'));
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
    $('#recs').html('');
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
// initialize player gui dom
function handle_playstatus_start (msg) {
    $('#playerdiv').html('');
    $('#playerdiv')
        .append(
            $('<div>').addClass('controls')
            .append($('<img>').attr('src','/icons/rewind10m.png').addClass('rewind10m'))
            .append($('<img>').attr('src','/icons/rewind1m.png').addClass('rewind1m'))
            .append($('<img>').attr('src','/icons/rewind10s.png').addClass('rewind10s'))
            .append($('<span>').addClass('playtime'))
            .append($('<img>').attr('src','/icons/forward10s.png').addClass('forward10s'))
            .append($('<img>').attr('src','/icons/forward1m.png').addClass('forward1m'))
            .append($('<img>').attr('src','/icons/forward10m.png').addClass('forward10m'))
        ).append(
            $('<div>').attr('id','previewpane')
            .append(
                $('<div>').attr('id','reloadpreviewbutton').addClass('icontextbutton')
                .append($('<img>').attr('src','/icons/refresh.png').attr('alt','reload'))
                .append($('<span>').html('click to load preview images'))
            )
            .append($('<div>').attr('id','seekstatus'))
            .append($('<div>').css('clear','both'))
            .append($('<div>').attr('id','previewend').css('clear','both'))
        ).append(
            $('<pre>').addClass('playlog')
        );
    $('.rewind10m').click(function (evt){send({cmd:"wind",seconds:-600});});
    $('.rewind1m').click(function (evt){send({cmd:"wind",seconds:-60});});
    $('.rewind10s').click(function (evt){send({cmd:"wind",seconds:-10});});
    $('.forward10s').click(function (evt){send({cmd:"wind",seconds:10});});
    $('.forward1m').click(function (evt){send({cmd:"wind",seconds:60});});
    $('.forward10m').click(function (evt){send({cmd:"wind",seconds:600});});
    $('#reloadpreviewbutton').click(function (evt){
        $('.previewimage').remove();
        send({cmd:"loadpreviewimages",interval:30,count:30,imgwidth:160});
    });
}
function handle_playstatus_update (msg) {
    if(typeof msg.reply.position !== 'undefined') {
        $('#playerdiv pre.playlog').append(msg.reply.position);
        $('#playerdiv pre.playlog').scrollTop($('#playerdiv pre.playlog')[0].scrollHeight);
    }
    if(typeof msg.reply.displaypos !== 'undefined') {
        $('#playerdiv .playtime').html(msg.reply.displaypos+' / '+msg.reply.displaylength);
    }
}
function get_picidx_from_preview_evt(dst,evt) {
    var w = $(dst).width();
    var center = $(dst).offset().left + w/2;
    var pointerRelX = evt.pageX - center;
    var center_picidx = parseInt($(dst).attr('picidx'));
    var left_picidx = $(dst).prev().attr('picidx');
    var right_picidx = $(dst).next().attr('picidx');
    var selected_picidx = null;
    if(pointerRelX < 0) {
        if(typeof left_picidx == 'undefined') return null;
        //console.debug(left_picidx + ' ' + right_picidx);
        var picidx_delta = center_picidx - parseInt(left_picidx);
        var picidx_per_width = picidx_delta / w;
        selected_picidx = center_picidx + picidx_per_width * pointerRelX;
    }
    else if(pointerRelX > 0) {
        if(typeof right_picidx == 'undefined') return null;
        //console.debug(left_picidx + ' ' + right_picidx);
        var picidx_delta = parseInt(right_picidx) - center_picidx;
        var picidx_per_width = picidx_delta / w;
        selected_picidx = center_picidx + picidx_per_width * pointerRelX;
    }
    else {
        selected_picidx = center_picidx;
    }
    return Math.round(selected_picidx);
}
function mouse_click_preview_handler (evt) {
    var selected_picidx = get_picidx_from_preview_evt(this,evt);
    if(selected_picidx == null) return;
    send({cmd:"seekpic",picidx:selected_picidx});
}
var single_preview_pending_picidx = null;
var next_single_preview_picidx = null;
function mouse_over_preview_handler (evt) {
    var selected_picidx = get_picidx_from_preview_evt(this,evt);
    
    if(selected_picidx == null) return;
    //console.debug(selected_picidx);
    
    if(single_preview_pending_picidx) {
        next_single_preview_picidx = selected_picidx;
        return;
    }
    
    single_preview_pending_picidx = selected_picidx;
    send({cmd:"loadsinglepreviewimage",picidx:single_preview_pending_picidx,imgwidth:160});
}
function handle_singlepreviewimage (msg) {
//    console.debug(msg.reply.displaypos);
    if($('#seekstatus img').length > 0) {
        $('#seekstatus img')
            .attr('src','data:image/jpg;base64,'+msg.reply.data)
            .attr('picidx',msg.reply.picidx)
            ;
        $('#seekpos').html(msg.reply.displaypos);
    } else {
        $('#seekstatus').html(
            $('<img>')
            .attr('src','data:image/jpg;base64,'+msg.reply.data)
            .attr('picidx',msg.reply.picidx)
            .addClass('singlepreviewimage')
            .after(
                $('<div>').attr('id','seekpos').addClass('seekpos').html(msg.reply.displaypos)
             )
        );
    }

    single_preview_pending_picidx = null;
    if(next_single_preview_picidx) {
        single_preview_pending_picidx = next_single_preview_picidx;
        next_single_preview_picidx = null;
        send({cmd:"loadsinglepreviewimage",picidx:single_preview_pending_picidx,imgwidth:160});
        setTimeout(function() {single_preview_pending_picidx=null;}, 3000);
    }
}
function handle_singlepreviewimagefail (msg) {
    single_preview_pending_picidx = null;
    if(next_single_preview_picidx) {
        single_preview_pending_picidx = next_single_preview_picidx;
        next_single_preview_picidx = null;
        send({cmd:"loadsinglepreviewimage",picidx:single_preview_pending_picidx,imgwidth:160});
        setTimeout(function() {single_preview_pending_picidx=null;}, 3000);
    }
}
function handle_previewimage (msg) {
    $('#previewend').before(
        $('<img>')
        .attr('src','data:image/jpg;base64,'+msg.reply.data)
        .attr('picidx',msg.reply.picidx)
        .addClass('previewimage')
        .mousemove(mouse_over_preview_handler)
        .click(mouse_click_preview_handler)
    );
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
            if(msg.cmd == 'previewimage') {
                handle_previewimage(msg);
            }
            if(msg.cmd == 'singlepreviewimage') {
                handle_singlepreviewimage(msg);
            }
            if(msg.cmd == 'singlepreviewimagefail') {
                handle_singlepreviewimagefail(msg);
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
    
    $('#reloadbutton').click(function(evt){
        $('#recs').html('loading ... please wait ...');
        send({cmd:"reload"});
    });
}
$(document).ready(onLoad);

