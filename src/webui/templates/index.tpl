<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Registrator</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/4.0.0/css/bootstrap.min.css" integrity="sha384-Gn5384xqQ1aoWXA+058RXPxPg6fy4IWvTNh0E263XmFcJlSAwiGgFAW/dAiS6JXm" crossorigin="anonymous">
    <style>
    body {
        margin:0;
        padding:0;
        font-family: Helvetica, sans-serif;
        background:#fbfbfb;
        padding-top: 40px; 
    }
    .card {
        margin: 0 auto;
        min-height:200px;
        box-shadow:0 5px 10px rgba(0,0,0,.2);
    }
    .card .box {
        position:absolute;
        top:50%;
        left:0;
        transform:translateY(-50%);
        text-align:center;
        padding:10px;
        box-sizing:border-box;
        width:100%;
    }
    .card .box h2 {
        font-size:20px;
        color:#262626;
        margin:15px auto;
    }
    .card .box h2 span {
        font-size:14px;
        background:#dd5e6e;
        color:#fff;
        display:inline-block;
        padding:4px 10px;
        border-radius:15px;
    }
    .card .box p {
        color:#262626;
    }
    .cust-btn-style {
        font-size:14px;
        background:#3c3c3d;
        color:#fff;
        display:inline-block;
        padding:4px 10px;
        border-radius:15px;
    }
    .cust-btn-style:hover {
        text-decoration: none;
        color: white;
    }
    .cust-a {
        text-decoration: none;
        color: black
    }
    .cust-a:hover {
        text-decoration: none;
        color: inherit;
    }
    .reg-form {
        margin: 0 auto;
    }
    .btn{
        margin: 4px;
        box-shadow: 1px 1px 5px #888888;
    }
    .btn-fresh {
        color: #fff;
        background-color: #51bf87;
        border-bottom:2px solid #41996c;
    }
    .btn-fresh:hover, .btn-fresh:focus {
        color: #fff;
        background-color: #66c796;
        border-bottom:2px solid #529f78;
        outline: none;
    }
    .txt-danger {
        color: #df6a78;
    }
    @media screen and (min-width: 767px) {
        .card {
            width: 350px;
        }
    }
</style>
</head>
<body>
    <div class="container">
        <div class="row">
            <div class="col-md-12 col-sm-12 col-xs-12">
                <h3 class="text-center text-uppercase">
                    <a class="cust-a" href="{{{:route_index}}}">Registrator</a>
                </h3>
                <div class="card">
                    <div class="box">
                        <h2>
                            Registry URL
                            <br>
                            <a href="{{{:registry_url}}}" target="_blank">
                                <span>{{{:registry_url}}}</span>
                            </a>
                        </h2>
                        <h2>
                            <a href="{{{:docs_url}}}" target="_blank">
                                <span>Click here for usage instructions</span>
                            </a>
                        </h2>
                    </div>
                </div>
            </div>
            <div class="col-md-12 col-sm-12 col-xs-12 mt-4">
                {{{:body}}}
            </div>
        </div>
    </div>
</body>
</html>
