package Text::Md2Inao;
use utf8;
use strict;
use warnings;

our $VERSION = '0.01';

use Class::Accessor::Fast qw/antlers/;
use Encode;
use HTML::TreeBuilder;
use List::Util 'max';
use Text::Markdown 'markdown';
use Unicode::EastAsianWidth;

# デフォルトのリストスタイル
# disc:   黒丸
# square: 四角
# circle: 白丸
# alpha:  アルファベット
has default_list => ( is => 'rw', isa => 'Str' );

# リストの文字数上限
# WEB+DB PRESSの場合、リストは、1行63桁（文字）まで
# 書籍の場合、リストは1行69桁（文字）まで
has max_list_length => ( is => 'rw', isa => 'Num' );

# 本文埋め込みリストの文字数上限
# WEB+DB PRESSの場合、本文リストは1行55桁（文字）まで
# 書籍の場合、本文リストは1行73桁（文字）まで
has max_inline_list_length => ( is => 'rw', isa => 'Num' );

sub parse {
    my ($self, $in) = @_;
    $self->{img_number} = 0;
    return $self->to_inao($in);
}

# 本文中に（◯1）や（1）など、リストを参照するときの形式に変換する
# 「リスト1.1(c1)を見てください」
# -> 
# 「リスト1.1（◯1）を見てください」となる
#
# (d1) -> （1）   # desc
# (c1) -> （◯1） # circle
# (s1) -> ［1］   # square
# (a1) -> （a）   # alpha
#
# エスケープも可能
# (\d1) -> (d1)
# (\c1) -> (c1)
sub to_list_style {
    my $text = shift;

    # convert
    $text =~ s/\(d(\d+)\)/（$1）/g;
    $text =~ s/\(c(\d+)\)/（○$1）/g;
    $text =~ s/\(s(\d+)\)/［$1］/g;
    $text =~ s/\(a(\d+)\)/'（' . chr($1 + 96)  . '）'/ge;

    # escape
    $text =~ s/\(\\([dcsa]?\d+)\)/($1)/g;

    return $text;
}

# 文字幅計算
# http://d.hatena.ne.jp/tokuhirom/20070514/1179108961
sub visual_length {
    local $_ = Encode::decode_utf8(shift);
    my $ret = 0;
    while (/(?:(\p{InFullwidth}+)|(\p{InHalfwidth}+))/g) { $ret += ($1 ? length($1)*2 : length($2)) }
    return $ret;
}

sub parse_inline {
    my $self = shift;
    my $elem = shift;
    my $is_special_italic = shift;
    my $ret = '';
    my $flag_note;

    for my $inline ($elem->content_list) {
        if (ref $inline eq '') {
            # (注:)は脚注としてあつかう
            if ($inline =~ m!\(注:!) {
                $inline =~ s!\(注:(.+?)!◆注/◆$1!gs;
                $flag_note++;
            }
            if ($inline =~ m!\)! && $flag_note) {
                $inline =~ s!\)!◆/注◆!;
                $flag_note--;
            }

            # 改行を取り除く
            $inline =~ s/(\n|\r)//g;

            # キャプション
            if ($inline =~ s!^●(.+?)::(.+)!●$1\t$2!) {
                $inline =~ s!\[(.+)\]$!\n$1!;
            }

            # リストスタイル文字の変換
            $inline = to_list_style($inline);

            $ret .= $inline;
        }
        elsif ($inline->tag eq 'a') {
            my $url   = $inline->attr('href');
            my $title = $inline->as_trimmed_text;
            $ret .= sprintf "%s◆注/◆%s◆/注◆", $title, $url;
        }
        elsif ($inline->tag eq 'img') {
            my $url   = $inline->attr('src');
            my $title = $inline->attr('alt') || $inline->attr('title');
            $ret .= sprintf(
                "●図%d\t%s\n%s\n",
                ++$self->{img_number},
                $title,
                $url,
            );
        }
        elsif ($inline->tag eq 'code') {
            $ret .= '◆cmd/◆';
            $ret .= $inline->as_trimmed_text;
            $ret .= '◆/cmd◆';
        }
        elsif ($inline->tag eq 'strong') {
            $ret .= '◆b/◆';
            $ret .= $inline->as_trimmed_text;
            $ret .= '◆/b◆';
        }
        elsif ($inline->tag eq 'em') {
            $ret .= $is_special_italic ? '◆i-j/◆' : '◆i/◆';
            $ret .= $inline->as_trimmed_text;
            $ret .= $is_special_italic ? '◆/i-j◆' : '◆/i◆';
        }
        elsif ($inline->tag eq 'kbd') {
            $ret .= $inline->as_trimmed_text;
            $ret .= '▲';
        }
        elsif ($inline->tag eq 'span') {
            my $class = $inline->attr('class');

            # 赤字
            # <span class='red'>赤字</span>
            if ($class eq 'red') {
                $ret .= '◆red/◆';
                $ret .= $inline->as_trimmed_text;
                $ret .= '◆/red◆';
            }

            # ruby
            # <span class='ruby'>漢字(かんじ)</span>
            elsif ($class eq 'ruby') {
                my $ruby = $inline->as_trimmed_text;
                $ruby =~ s!(.+)\((.+)\)!◆ルビ/◆$1◆$2◆/ルビ◆!;
                $ret .= $ruby;
            }

            # その他の記号
            # <span class='symbol'>＝＞</span>
            elsif ($class eq 'symbol') {
                $ret .= '◆';
                $ret .= $inline->as_trimmed_text;
                $ret .= '◆';
            }
        }
    }
    return $ret;
}

sub to_html_tree {
    my $text = shift;

    ## Work Around: Text::Markdown が flagged string だと一部 buggy なので encode してから渡している
    my $html = decode_utf8 markdown(encode_utf8 $text);

    my $tree = HTML::TreeBuilder->new;
    $tree->no_space_compacting(1);
    $tree->parse_content(\$html);
}

sub to_inao {
    my ($self, $text, $is_column) = @_;

    my $tree = to_html_tree($text);
    my $inao = q[];
    my $body = $tree->find('body');

    for my $elem ($body->content_list) {
        if ($elem->tag =~ /^h(\d+)/) {
            my $level = $1;

            $inao .= '■' x $level;
            $inao .= $elem->as_trimmed_text;
            $inao .= "\n";
        }
        elsif ($elem->tag eq 'p') {
            my $p = $self->parse_inline($elem, $is_column);

            if ($p !~ /^[\s　]+$/) {
                $inao .= "$p\n";
            }
        }
        elsif ($elem->tag eq 'pre') {
            my $code = $elem->find('code');
            my $text = $code ? $code->as_text : '';
            my $list_label = 'list';
            my $comment_label = 'comment';

            # キャプション
            $text =~ s!●(.+?)::(.+)!●$1\t$2!g;

            # 「!!! cmd」で始まるコードブロックはコマンドライン（黒背景）
            if ($text =~ /!!!(\s+)?cmd/) {
                $text =~ s/.+?\n//;
                $list_label .= '-white';
                $comment_label .= '-white';
            }

            # リストスタイル
            $text = to_list_style($text);

            # 文字数カウント
            my $max = max(map { visual_length($_) } split /\r?\n/, $text);
            if ($text =~ /^●/) {
                if ($max > $self->max_list_length) {
                    warn "リストは" . $self->max_list_length . "文字まで！(現在${max}使用):\n$text\n\n";
                }
            }
            else {
                if ($max > $self->max_inline_list_length) {
                    warn "本文埋め込みリストは" . $self->max_inline_list_length . "文字まで！(現在${max}使用):\n$text\n\n";
                }
            }

            # コード内コメント
            $text =~ s!\(注:(.+?)\)!◆$comment_label/◆$1◆/$comment_label◆!g;

            # コード内強調
            $text =~ s!\*\*(.+?)\*\*!◆cmd-b/◆$1◆/cmd-b◆!g;

            # コード内イタリック
            $text =~ s!\___(.+?)\___!◆i-j/◆$1◆/i-j◆!g;

            $inao .= "◆$list_label/◆\n";
            $inao .= $text;
            $inao .= "◆/$list_label◆\n";
        }
        elsif ($elem->tag eq 'ul') {
            for my $list ($elem->find('li')) {
                $inao .= '・' . $self->parse_inline($list, 1) . "\n";
            }
        }
        elsif ($elem->tag eq 'ol') {
            my $list_style = $elem->attr('class') || $self->default_list;
            my $s = substr $list_style, 0, 1;
            my $i = 0;
            for my $list ($elem->find('li')) {
                $inao .=
                    to_list_style((sprintf('(%s%d)', $s, ++$i)) .
                    $self->parse_inline($list, 1)) . "\n";
            }
        }
        elsif ($elem->tag eq 'table') {
            my $summary = $elem->attr('summary') || '';
            $summary =~ s!(.+?)::(.+)!●$1\t$2\n!;
            $inao .= "◆table/◆\n";
            $inao .= $summary;
            $inao .= "◆table-title◆";
            for my $table ($elem->find('tr')) {
                for my $item ($table->find('th')){
                    $inao .= $item->as_trimmed_text;
                    $inao .= "\t";
                }
                for my $item ($table->find('td')){
                    $inao .= $item->as_trimmed_text;
                    $inao .= "\t";
                }
                chop($inao);
                $inao .= "\n"
            }
            $inao .= "◆/table◆\n";
        }
        elsif ($elem->tag eq 'div' and $elem->attr('class') eq 'column') {
            # HTMLとして取得してcolumn自信のdivタグを削除
            my $html = $elem->as_HTML('');
            $html =~ s/^<div.+?>//;
            $html =~ s/<\/div>$//;

            $inao .= "◆column/◆\n";
            $inao .= $self->to_inao($html, 1);
            $inao .= "◆/column◆\n";
        }
        elsif ($elem->tag eq 'blockquote') {
            my $blockquote = '';
            for my $p ($elem->content_list) {
                $blockquote = $self->parse_inline($p, 1);
            }
            $blockquote =~ s/(\s)//g;
            $inao .= "◆quote/◆\n";
            $inao .= $blockquote;
            $inao .= "\n◆/quote◆\n";
        }
    }

    return $inao;
}

1;
