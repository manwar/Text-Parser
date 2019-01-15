use warnings;
use strict;

package Text::Parser;

# ABSTRACT: Bare text parser, bundles many common "mundane" tasks.

use Exporter 'import';
our (@EXPORT_OK) = ();
our (@EXPORT)    = (@EXPORT_OK);

=head1 SYNOPSIS

    use Text::Parser;

    my $parser = Text::Parser->new();
    $parser->read(shift @ARGV);
    print $parser->get_records, "\n";

The above code reads the first command-line argument as a string, and assuming it is the name of a text file, it will print the content of the file to C<STDOUT>. If the string is not the name of a text file it will throw an exception and exit.

=head1 RATIONALE

A simple text file parser should have to only specify the "grammar" it intends to interpret. Everything else, like C<open>ing a file handle, tracking how many lines have been read, etc., should be "automatic".

Unfortunately, most programmers write code that calls C<open>, C<close>, etc., and keep track of things that should have been simple features of every text file parser. And if they have to read multiple files, usually, all these calls are repeated.

Furthermore, there are times when a text format has what should have been one one line, spread out over several lines. Typically this is done to improve human readability, and uses some sort of continuation character. For example, the bash and other shells treat a trailing back-slash (C<\>) character as a line-continuation character. In such cases, the parser has to do additional tasks of book-keeping. It has to:

=for :list
* join the continuing lines intelligently to read what all was intended on one line
* report any errors in this process of detecting line-continuations etc.

Doing all this along with parsing for the actual data can get hairy and confusing. This class is meant to simplify all that.

First, it does all "mundane" operations like C<open>, C<close>, line-count, and storage/deletion/retrieval of records, etc. You don't have to bother with a lot of book-keeping when you write your next parser. Instead, just inherit this class and override one method (C<L<save_record|/save_record>>). And voila! you have a parser. Look at L<these examples|/EXAMPLES> to see how easy this can be.

Second, if data is expected to be on multiple lines, it is easy to setup a multi-line parser too. See L<these examples|/"Example 4 : Multi-line parsing"> for more on that. Also see L<Text::Parser::Multiline> for how it actually works.

=head1 DESCRIPTION

C<Text::Parser> is a bare-bones text parsing class. It is ignorant of the text format, and cannot recognize any grammars, but derived classes that inherit from it can specify this. They can do this usually by overriding just one of the methods in this class.

Future versions are expected to include progress-bar support, parsing text from sockets, or a chunk of memory. All these software features are text-format independent and can be re-used in parsing any text format. Derived classes of C<Text::Parser> will be able to take advantage of these features.

=cut

use Exception::Class (
    'Text::Parser::Exception',
    'Text::Parser::Exception::ParsingError' => {
        isa         => 'Text::Parser::Exception',
        description => 'For all parsing errors',
        alias       => 'throw_text_parsing_error'
    },
    'Text::Parser::Exception::FileNotFound' => {
        isa         => 'Text::Parser::Exception',
        description => 'File not found',
        alias       => 'throw_file_not_found'
    },
    'Text::Parser::Exception::FileNotReadable' => {
        isa         => 'Text::Parser::Exception',
        description => 'File not readable',
        alias       => 'throw_file_not_readable'
    },
    'Text::Parser::Exception::InvalidFileHandle' => {
        isa         => 'Text::Parser::Exception',
        description => 'Bad argument supplied to filehandle()',
        alias       => 'throw_invalid_filehandle'
    },
    'Text::Parser::Exception::InvalidFilename' => {
        isa         => 'Text::Parser::Exception',
        description => 'Bad argument supplied to filename()',
        alias       => 'throw_bad_filename'
    },
    'Text::Parser::Exception::FileCantOpen' => {
        isa         => 'Text::Parser::Exception',
        description => 'Error opening file',
        alias       => 'throw_cant_open'
    },
    'Text::Parser::Exception::BadReadInput' => {
        isa => 'Text::Parser::Exception',
        description =>
            'The user called read() method with an unsupported type of input',
        alias => 'throw_bad_input_to_read',
    },
);

use Try::Tiny;
use Scalar::Util 'openhandle';
use Role::Tiny;

=method new

Constructor. Takes options in the form of a hash. The options and their allowed values are:

    auto_chomp     => 0|1                     (Default: 0)
    mutliline_type => 'join_next'|'join_last' (Default: undef)

You can thus create an object of a parser like this.

    my $parser = Text::Parser->new(auto_chomp => 1, multiline_type => 'join_last');
    $parser = Text::Parser->new(); # Default auto_chomp => 0

This C<$parser> variable will be used in examples below.

=head3 Notes on the options

The options have the following interpretation:

     auto_chomp => 0 : Don't chomp lines automatically before calling save_record() - Default
     auto_chomp => 1 : Automatically chomp lines before calling save_record()

     multiline_type => 'join_next' : Multi-line parser, that continues current line in the next line
     multiline_type => 'join_last' : Multi-line parser, that continues previous line in the current line
                    => undef (Default)

=cut

sub new {
    my $pkg = shift;
    return undef if not __check_options(@_);
    my $hash = __set_options(@_);
    my $obj  = bless { __options => $hash }, $pkg;
    return $obj->__return_my_object();
}

my (%allowed_options)
    = ( auto_chomp => '0|1', multiline_type => 'join_next|join_last' );
my (%default_values) = ( auto_chomp => 0, multiline_type => undef );

sub __check_options {
    my (%opt) = @_;
    foreach my $k ( keys %opt ) {
        return 0 if not exists $allowed_options{$k};
        my (@allowed) = split /\s*[|]\s*/, $allowed_options{$k};
        return 0 if not grep { $_ eq $opt{$k} } @allowed;
    }
    return 1;
}

sub __set_options {
    my (%opt) = @_;
    foreach my $k ( keys %default_values ) {
        $opt{$k} = $default_values{$k} if not exists $opt{$k};
    }
    return \%opt;
}

sub __return_my_object {
    my $obj = shift;
    return $obj if not defined $obj->setting('multiline_type');
    Role::Tiny->apply_roles_to_object( $obj, 'Text::Parser::Multiline' );
    return $obj;
}

=method setting

Takes a single string as argument, and returns the value of that setting. The string must be one of:

    auto_chomp
    multiline_type

These settings are set during the parser construction.

=cut

sub setting {
    my ( $self, $key ) = ( shift, shift );
    return undef if not defined $key or not exists $self->{__options}{$key};
    return $self->{__options}{$key};
}

=method read

Takes zero or one argument which could be a string containing the name of the file, or a filehandle reference or a C<GLOB> (e.g. C<\*STDIN>). Throws an exception if filename/C<GLOB> provided is either non-existent or cannot be read for any reason.

B<Note:> Normally if you provide the C<GLOB> of a file opened for write, some Operating Systems allow reading from it too, and some don't. Read the documentation for C<L<filehandle|/filehandle>> for more on this.

    $parser->read($filename);

    # The above is equivalent to the following
    $parser->filename($filename);
    $parser->read();

    # You can also read from a previously opened file handle directly
    $parser->filehandle(\*STDIN);
    $parser->read();

Returns once all records have been read or if an exception is thrown for any parsing errors, or if reading has been aborted with the C<L<abort_reading|/abort_reading>> method.

If you provide a string file name as input, the function will handle all C<open> and C<close> operations on files even if any exception is thrown, or if the reading has been aborted. But if you pass a file handle C<GLOB> instead, then the file handle won't be closed and it will be the responsibility of the calling program to close the filehandle.

    $parser->read('myfile.txt');
    # Will handle open, parsing, and closing of file automatically.

    open MYFH, "<myfile.txt" or die "Can't open file myfile.txt at ";
    $parser->read(\*MYFH);
    # Will not close MYFH and it is the respo
    close MYFH;

When you do read a new file or input stream with this method, you will lose all the records stored from the previous read operation. So this means that if you want to read a different file with the same parser object, (unless you don't care about the records from the last file you read) you should use the C<L<get_records|/get_records>> method to retrieve all the read records before parsing a new file. So all those calls to C<read> in the example above were parsing three different files, and each successive call overwrote the records from the previous call.

    $parser->read($file1);
    my (@records) = $parser->get_records();

    $parser->read(\*STDIN);
    my (@stdin) = $parser->get_records();

B<Inheritance Recommendation:> To extend the class to other file formats, override C<L<save_record|/save_record>> instead of this one.

=head3 Future Enhancement

I<At present the C<read> method takes only two possible inputs argument types, either a file name, or a file handle. In future this may be enhanced to read from sockets, subroutines, or even just a block of memory (a string reference). Suggestions for other forms of input are welcome.>

=cut

sub read {
    my ( $self, $input ) = @_;
    return if not $self->__is_file_known_or_opened($input);
    $self->__store_check_input($input);
    $self->__read_and_close_filehandle();
}

sub __store_check_input {
    my ( $self, $input ) = @_;
    return                           if not defined $input;
    return $self->filename($input)   if ref($input) eq '';
    return $self->filehandle($input) if ref($input) eq 'GLOB';
    __throw_bad_input_to_read( ref($input) );
}

sub __throw_bad_input_to_read {
    throw_bad_input_to_read error => 'Unexpected ' . shift
        . ' type input to read() ; must be either string filename or GLOB';
}

sub __is_file_known_or_opened {
    my ( $self, $fname ) = @_;
    return 0 if not defined $fname and not exists $self->{__filehandle};
    return 0 if defined $fname and not $fname;
    return 1;
}

sub __read_and_close_filehandle {
    my $self = shift;
    $self->__init_read_fh;
    $self->__read_file_handle;
    $self->__close_file;
}

sub __init_read_fh {
    my $self = shift;
    $self->lines_parsed(0);
    $self->{__bytes_read} = 0;
    delete $self->{__records} if exists $self->{__records};
    delete $self->{__abort_reading};
}

sub __read_file_handle {
    my $self = shift;
    my $fh   = $self->filehandle();
    while (<$fh>) {
        last if not $self->__parse_line_and_next($_);
    }
}

sub __parse_line_and_next {
    my ( $self, $line ) = ( shift, shift );
    $self->lines_parsed( $self->lines_parsed + 1 );
    chomp $line if $self->setting('auto_chomp');
    $self->__try_to_parse($line);
    return not exists $self->{__abort_reading};
}

sub __try_to_parse {
    my ( $self, $line ) = @_;
    try { $self->save_record($line); }
    catch {
        $self->__close_file;
        $_->rethrow;
    };
}

sub __close_file {
    my $self = shift;
    return if not exists $self->{__filename};
    close $self->{__filehandle};
    delete $self->{__filehandle};
}

=method filename

Takes zero or one string argument containing the name of a file. Returns the name of the file that was last opened if any. Returns C<undef> if no file has been opened.

    print "Last read ", $parser->filename, "\n";

The file name is "persistent" in the object. Meaning, even after you have called C<L<read|/read>> once, it still remembers the file name. So you can do this:

    $parser->read(shift @ARGV);
    print $parser->filename(), ":\n",
          "=" x (length($parser->filename())+1),
          "\n",
          $parser->get_records(),
          "\n";

But if you do a C<read> with a filehandle as argument, you'll see that the last filename is lost - which makes sense.

    $parser->read(\*MYFH);
    print "Last file name is lost\n" if not defined $parser->filename();

=cut

sub filename {
    my $self = shift;
    $self->__open_file( $self->__is_readable_file(shift) ) if scalar(@_);
    return ( exists $self->{__filename} ) ? $self->{__filename} : undef;
}

sub __is_readable_file {
    my ( $self, $fname ) = @_;
    throw_bad_filename( error => "$fname is not a string" )
        if ref($fname) ne '';
    throw_file_not_found( error => "$fname is not a file" )
        if not -f $fname;
    throw_file_not_readable( error => "$fname is not readable" )
        if not -r $fname;
    return $fname;
}

sub __open_file {
    my ( $self, $fname ) = @_;
    open my $fh, "<$fname"
        or throw_cant_open( error => "Error while opening file $fname" );
    $self->__close_file if exists $self->{__filehandle};
    $self->{__filename}   = $fname;
    $self->{__filehandle} = $fh;
}

=method filehandle

Takes zero or one C<GLOB> argument and saves it for future a C<L<read|/read>> call. Returns the filehandle last saved, or C<undef> if none was saved. Remember that after a successful C<read> call, filehandles are lost.

    my $fh = $parser->filehandle();

B<Note:> As such there is a check to ensure one is not supplying a write-only filehandle. For example, if you specify the filehandle of a write-only file or if the file is opened for write and you cannot read from it. The weird thing is that some of the standard filehandles like C<STDOUT> don't behave uniformly across all platforms. On most POSIX platforms, C<STDOUT> is readable. On such platforms you will not get any exceptions if you try to do this:

    $parser->filehandle(\*STDOUT);  ## Works on many POSIX platforms
                                    ## Throws exception on others

Like in the case of C<L<filename|/filename>> method, if after you C<read> with a filehandle, you call C<read> again, this time with a file name, the last filehandle is lost.

    my $lastfh = $parser->filehandle();
    ## Will return STDOUT
    
    $parser->read('another.txt');
    print "No filehandle saved any more\n" if
                        not defined $parser->filehandle();

=cut

sub filehandle {
    my ( $self, $fhref ) = @_;
    $self->__save_file_handle($fhref) if $self->__check_file_handle($fhref);
    return ( exists $self->{__filehandle} ) ? $self->{__filehandle} : undef;
}

sub __save_file_handle {
    my ( $self, $fhref ) = @_;
    $self->{__filehandle} = $$fhref;
    delete $self->{__filename} if exists $self->{__filename};
    $self->{__size} = ( stat $$fhref )[7];
}

sub __check_file_handle {
    my ( $self, $fhref ) = @_;
    return 0 if not defined $fhref;
    throw_invalid_filehandle( error => "$fhref is not a valid filehandle" )
        if ref($fhref) ne 'GLOB';
    throw_file_not_readable( error => "$$fhref is a closed filehandle" )
        if not defined openhandle($fhref);
    throw_file_not_readable(
        error => "The filehandle $$fhref is not readable" )
        if not -r $$fhref;
    return 1;
}

=method lines_parsed

Takes no arguments. Returns the number of lines last parsed. A line is reckoned when the C<\n> character is encountered.

    print $parser->lines_parsed, " lines were parsed\n";

The value is auto-updated during the execution of C<L<read|/read>>. See L<this example|/"Example 2 : Error checking"> of how this can be used in derived classes.

Again the information in this is "persistent". You can also be assured that every time you call C<read>, the value be auto-reset before parsing.

=cut

sub lines_parsed {
    my $self = shift;
    return $self->{__current_line} = shift if @_;
    return ( exists $self->{__current_line} ) ? $self->{__current_line} : 0;
}

=method save_record

Takes exactly one argument and that is saved as a record. Additional arguments are ignored. If no arguments are passed, then C<undef> is stored as a record.

In an application that uses a text parser, you will most-likely never call this method directly. It is automatically called within C<L<read|/read>> for each line. In this base class C<Text::Parser>, C<save_record> is simply called with a string containing the raw line of text ; i.e. the line of text will not be C<chomp>ed or modified in any way. L<Here|/"Example 1 : A simple CSV Parser"> is a basic example.

Derived classes can decide to store records in a different form. A derived class could, for example, store the records in the form of hash references (so that when you use C<L<get_records|/get_records>>, you'd get an array of hashes), or maybe even another array reference (so when you use C<get_records> you'd get an array of arrays). The L<CSV parser example|/"Example 1 : A simple CSV Parser"> does the latter.

=cut

sub save_record {
    my $self = shift;
    $self->{__records} = [] if not defined $self->{__records};
    push @{ $self->{__records} }, shift;
}

=method abort_reading

Takes no arguments. Returns C<1>. You will probably never call this method in your main program.

This method is usually used only in the derived class. See L<this example|/"Example 3 : Aborting without errors">.

=cut

sub abort_reading {
    my $self = shift;
    return $self->{__abort_reading} = 1;
}

=method get_records

Takes no arguments. Returns an array containing all the records saved by the parser.

    foreach my $record ( $parser->get_records ) {
        $i++;
        print "Record: $i: ", $record, "\n";
    }

=cut

sub get_records {
    my $self = shift;
    return () if not exists $self->{__records};
    return @{ $self->{__records} };
}

=method last_record

Takes no arguments and returns the last saved record. Leaves the saved records untouched.

    my $last_rec = $parser->last_record;

=cut

sub last_record {
    my $self = shift;
    return undef if not exists $self->{__records};
    my (@record) = @{ $self->{__records} };
    return $record[$#record];
}

=method pop_record

Takes no arguments and pops the last saved record.

    my $last_rec = $parser->pop_record;
    $uc_last = uc $last_rec;
    $parser->save_record($uc_last);

=cut

sub pop_record {
    my $self = shift;
    return undef if not exists $self->{__records};
    pop @{ $self->{__records} };
}

=method is_line_continued

Takes a string argument. The default method provided will return C<0> if the parser is not a multi-line parser. If it is a multi-line parser, return value depends on the type of multiline parser. 

If it is of type C<'join_last'>, then it returns C<1> for all lines except the first line. This means all lines continue from the previous line (except the first line, because there is no line before that).

But if it is of type C<'join_next'>, then it returns C<1> for all lines unconditionally. This means the parser will expect further lines, even when the last line in the text input has been read. Thus you need to have a way to indicate that there is no further continuation. This is why if you are building a trivial line-joiner, you should use the C<'join_last'> type. See L<this example|/"Trivial line-joiner">.

    $parser->is_line_continued();

=cut

sub is_line_continued {
    my $self = shift;
    return 0 if not defined $self->setting('multiline_type');
    return 0
        if $self->setting('multiline_type') eq 'join_last'
        and $self->lines_parsed() == 1;
    return 1;
}

=method join_last_line

This method is used in multi-line text parsing. The method takes two string arguments. The default implementation just concatenates two strings and returns the result. You should redefine this method to strip any continuation characters and join the strings with any required spaces etc.

    $parser->join_last_line('last line', ' + this line');

=cut

sub join_last_line {
    my $self = shift;
    my ( $last, $line ) = ( shift, shift );
    return $last . $line;
}

=method has_aborted

Takes no arguments, returns a boolean to indicate if text reading was aborted in the middle. This method is used in multi-line parsers.

    print "Aborted\n" if $parser->has_aborted();

=cut

sub has_aborted {
    my $self = shift;
    return $self->{__abort_reading} if exists $self->{__abort_reading};
    return 0;
}

=head1 EXAMPLES

The following examples should illustrate the use of inheritance to parse various types of text file formats.

=head2 Basic principle

Derived classes simply need to override one method : C<L<save_record|/save_record>>. With the help of that any arbitrary file format can be read. C<save_record> should interpret the format of the text and store it in some form by calling C<SUPER::save_record>. The C<main::> program will then use the records and create an appropriate data structure with it.

Notice that the creation of a data structure is not the objective of a parser. It is simply concerned with collecting data and arranging it in a form that can be used. That's all. Data structures can be created by a different part of your program using the data collected by your parser.

=head2 Example 1 : A simple CSV Parser

We will write a parser for a simple CSV file that reads each line and stores the records as array references. This example is oversimplified, and does B<not> handle embedded newlines.

    package Text::Parser::CSV;
    use parent 'Text::Parser';
    use Text::CSV;

    my $csv;
    sub save_record {
        my ($self, $line) = @_;
        $csv //= Text::CSV->new({ binary => 1, auto_diag => 1});
        $csv->parse($line);
        $self->SUPER::save_record([$csv->fields]);
    }

That's it! Now in C<main::> you can write something like this:

    use Text::Parser::CSV;
    
    my $csvp = Text::Parser::CSV->new();
    $csvp->read(shift @ARGV);
    foreach my $aref ($csvp->get_records) {
        my (@arr) = @{$aref};
        print "@arr\n";
    }

The above program reads the content of a given CSV file and prints the content out in space-separated form.

=head2 Example 2 : Error checking

It is easy to add any error checks using exceptions. One of the easiest ways to do this is to C<use L<Exception::Class>>. We'll modify the CSV parser above to demonstrate that.

    package Text::Parser::CSV;
    use Exception::Class (
        'Text::Parser::CSV::Error', 
        'Text::Parser::CSV::TooManyFields' => {
            isa => 'Text::Parser::CSV::Error',
        },
    );
    
    use parent 'Text::Parser';
    use Text::CSV;

    my $csv;
    sub save_record {
        my ($self, $line) = @_;
        $csv //= Text::CSV->new({ binary => 1, auto_diag => 1});
        $csv->parse($line);
        my @fields = $csv->fields;
        $self->{__csv_header} = \@fields if not scalar($self->get_records);
        Text::Parser::CSV::TooManyFields->throw(error => "Too many fields on line #" . $self->lines_parsed)
            if scalar(@fields) > scalar(@{$self->{__csv_header}});
        $self->SUPER::save_record(\@fields);
    }

The C<Text::Parser> class will C<close> all filehandles automatically as soon as an exception is thrown from C<save_record>. You can catch the exception in C<main::> as you would normally, by C<use>ing C<L<Try::Tiny>> or other such class.

=head2 Example 3 : Aborting without errors

We can also abort parsing a text file without throwing an exception. This could be if we got the information we needed. For example:

    package Text::Parser::SomeFile;
    use parent 'Text::Parser';

    sub save_record {
        my ($self, $line) = @_;
        my ($leading, $rest) = split /\s+/, $line, 2;
        return $self->abort_reading() if $leading eq '**ABORT';
        return $self->SUPER::save_record($line);
    }

In this derived class, we have a parser C<Text::Parser::SomeFile> that would save each line as a record, but would abort reading the rest of the file as soon as it reaches a line with C<**ABORT> as the first word. When this parser is given the following file as input:

    somefile.txt:

    Some text is here.
    More text here.
    **ABORT reading
    This text is not read
    This text is not read
    This text is not read
    This text is not read

You can now write a program as follows:

    use Text::Parser::SomeFile;

    my $par = Text::Parser::SomeFile->new();
    $par->read('somefile.txt');
    print $par->get_records(), "\n";

The output will be:

    Some text is here.
    More text here.

=head2 Example 4 : Multi-line parsing

Some text formats allow users to split a line into several lines with a line continuation character (usually at the end or the beginning of a line).

=head3 Trivial line-joiner

Below is a trivial example where all lines are joined into one:

    use strict;
    use warnings;
    use Text::Parser;

    my $join_all = Text::Parser->new(auto_chomp => 1, multiline_type => 'join_last');
    $join_all->read('input.txt');
    print $join_all->get_records(), "\n";

Another trivial example is L<here|Text::Parser::Multiline/SYNOPSIS>.

=head3 Continue with character

(Pun intended! ;-))

In the above example, all lines are joined (indiscriminately). But most often text formats have a continuation character that specifies that the line continues to the next line, or that the line is a continuation of the I<previous> line. Here's an example parser that treats the back-slash (C<\>) character as a line-continuation character:

    package MyMultilineParser;
    use parent 'Text::Parser';
    use strict;
    use warnings;

    sub new {
        my $pkg = shift;
        $pkg->SUPER::new(multiline_type => 'join_next');
    }

    sub is_line_continued {
        my $self = shift;
        my $line = shift;
        chomp $line;
        return $line =~ /\\\s*$/;
    }

    sub join_last_line {
        my $self = shift;
        my ($last, $line) = (shift, shift);
        chomp $last;
        $last =~ s/\\\s*$/ /g;
        return $last . $line;
    }

    1;

In your C<main::>

    use MyMultilineParser;
    use strict;
    use warnings;

    my $parser = MyMultilineParser->new();
    $parser->read('multiline.txt');
    print "Read:\n"
    print $parser->get_records(), "\n";

Try with the following input F<multiline.txt>:

    Garbage In.\
    Garbage Out!

When you run the above code with this file, you should get:

    Read:
    Garbage In. Garbage Out!

=head3 Simple SPICE line joiner

Some text formats allow a line to indicate that it is continuing from a previous line. For example L<SPICE|https://bwrcs.eecs.berkeley.edu/Classes/IcBook/SPICE/> has a continuation character (C<+>) on the next line, indicating that the text on that line should be joined with the I<previous> line. Let's show how to build a simple SPICE line-joiner. To build a full-fledged parser you will have to specify the rich and complex grammar for SPICE circuit description.

    use TrivialSpiceJoin;
    use parent 'Text::Parser';

    use constant {
        SPICE_LINE_CONTD => qr/^[+]\s*/,
        SPICE_END_FILE   => qr/^\.end/i,
    };

    sub new {
        my $pkg = shift;
        $pkg->SUPER::new(auto_chomp => 1, multiline_type => 'join_last');
    }

    sub is_line_continued {
        my ( $self, $line ) = @_;
        return 0 if not defined $line;
        return $line =~ SPICE_LINE_CONTD;
    }
    
    sub join_last_line {
        my ( $self, $last, $line ) = ( shift, shift, shift );
        return $last if not defined $line;
        $line =~ s/^[+]\s*/ /;
        return $line if not defined $last;
        return $last . $line;
    }

    sub save_record {
        my ( $self, $line ) = @_;
        return $self->abort_reading() if $line =~ SPICE_END_FILE;
        $self->SUPER::save_record($line);
    }

Try this parser with a simple SPICE deck and see what you get. You may now write a more elaborate method for C<save_record> above and that could be used to parse a full SPICE file.

=cut

1;
